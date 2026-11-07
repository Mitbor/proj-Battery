// App state: settings, live MQTT stream, HTTP fallback, widget updates, low-battery notification.

import Foundation
import SwiftUI
import WidgetKit
import UserNotifications
import ServiceManagement

@MainActor
final class BatteryModel: ObservableObject {
    @Published var snapshot: BatterySnapshot?
    @Published var status = "Starting…"
    @Published var settings = AppSettings.load()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let liveStaleSec: TimeInterval = 120
    private var live: [String: Any] = [:]
    private var lastLive = Date.distantPast
    private var feed: MQTTFeed?
    private var generation = 0               // ignores callbacks from a feed that was replaced
    private var reconnectDelay: TimeInterval = 5
    private var deviceName = "EcoFlow"
    private var timer: Timer?
    private var lastFallback = Date.distantPast
    private var lowWarned = false
    private var widgetKey = ""
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetSave = Date.distantPast

    var liveFresh: Bool { Date().timeIntervalSince(lastLive) < liveStaleSec }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        restart()
    }

    // ---------------------------------------------------------------- lifecycle
    func apply(_ s: AppSettings) {
        settings = s
        s.save()
        lowWarned = false
        restart()
    }

    func restart() {
        generation += 1
        feed?.stop(); feed = nil
        live = [:]; lastLive = .distantPast; reconnectDelay = 5
        guard settings.isComplete else { status = "Open Settings and enter your EcoFlow keys"; return }
        status = "Connecting…"
        Task { await fetchSnapshot() }
        connectLive()
    }

    private func tick() {
        guard settings.isComplete else { return }
        if lastLive != .distantPast && !liveFresh {
            // the stream went silent — the station went offline or the internet dropped
            lastLive = .distantPast
            status = "No live data for \(Int(liveStaleSec)) s, reconnecting…"
            restart()
            return
        }
        if !liveFresh && Date().timeIntervalSince(lastFallback) >= TimeInterval(settings.intervalSec) {
            Task { await fetchSnapshot() }
        }
    }

    // ---------------------------------------------------------------- HTTP fallback
    private func ensureSerial(_ api: EcoFlowAPI) async throws -> String {
        if !settings.serial.isEmpty { return settings.serial }
        let devs = try await api.listDevices()
        guard let dev = devs.first(where: EcoFlowAPI.isStation) ?? devs.first,
              let sn = dev["sn"] as? String else { throw APIError(message: "No devices are linked to this account") }
        settings.serial = sn
        settings.save()
        return sn
    }

    func fetchSnapshot() async {
        lastFallback = Date()
        let api = settings.api
        do {
            let sn = try await ensureSerial(api)
            var online = true
            if let me = try? await api.listDevices().first(where: { "\($0["sn"] ?? "")" == sn }) {
                online = "\(me["online"] ?? 1)" == "1"
                let pn = "\(me["productName"] ?? "")"
                if !pn.isEmpty { deviceName = pn }
            }
            let q = try await api.quotaAll(sn: sn)
            guard !liveFresh else { return }                    // live data takes priority over the cache
            guard let s = BatterySnapshot.from(q, name: deviceName, live: false, online: online) else {
                throw APIError(message: "No battery level in the response")
            }
            show(s)
        } catch {
            if !liveFresh { status = "Error: \(error.localizedDescription)" }
        }
    }

    // ---------------------------------------------------------------- live MQTT
    private func connectLive() {
        let gen = generation
        let api = settings.api
        Task {
            do {
                let sn = try await ensureSerial(api)
                let cert = try await api.certification()
                guard gen == generation else { return }
                let user = "\(cert["certificateAccount"] ?? "")"
                let pass = "\(cert["certificatePassword"] ?? "")"
                let host = "\(cert["url"] ?? "")"
                let port = UInt16("\(cert["port"] ?? 8883)") ?? 8883

                let f = MQTTFeed()
                f.onParams = { [weak self] p in
                    Task { @MainActor in self?.ingest(p, gen: gen) }
                }
                f.onClosed = { [weak self] reason in
                    Task { @MainActor in self?.liveClosed(reason, gen: gen) }
                }
                feed = f
                f.connect(host: host, port: port, user: user, password: pass, topic: "/open/\(user)/\(sn)/quota")
            } catch {
                liveClosed(error.localizedDescription, gen: gen)
            }
        }
    }

    private func liveClosed(_ reason: String, gen: Int) {
        guard gen == generation else { return }
        NSLog("EcoFlowTray MQTT: %@", reason)
        if !liveFresh { status = "No live data: \(reason)" }
        let delay = reconnectDelay
        reconnectDelay = min(120, reconnectDelay * 2)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard gen == generation else { return }
            connectLive()
        }
    }

    private func ingest(_ p: [String: Any], gen: Int) {
        guard gen == generation else { return }
        for (k, v) in p { live[k] = v }
        lastLive = Date()
        reconnectDelay = 5
        guard var s = BatterySnapshot.from(live, name: deviceName, live: true) else { return }   // first packets may lack the level
        s.updated = lastLive
        show(s)
    }

    // ---------------------------------------------------------------- output
    private func show(_ s: BatterySnapshot) {
        snapshot = s
        status = s.live ? "Live" : (s.online ? "Cloud cache, may be out of date" : "Station is offline — last known level")
        publishToWidget(s)

        if !s.charging && s.soc <= settings.lowThreshold && !lowWarned {
            lowWarned = true
            let c = UNMutableNotificationContent()
            c.title = s.name
            c.body = "Low battery: \(s.soc)%"
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low", content: c, trigger: nil))
        }
        if s.soc > settings.lowThreshold + 5 || s.charging { lowWarned = false }
    }

    // macOS limits how often an app may refresh widgets, so reload only on meaningful changes.
    private func publishToWidget(_ s: BatterySnapshot) {
        let now = Date()
        let key = "\(s.soc)|\(s.charging)|\(s.online)|\(s.live)"
        let changed = key != widgetKey
        if changed || now.timeIntervalSince(lastWidgetSave) > 60 {
            SharedStore.save(s)
            lastWidgetSave = now
        }
        if (changed && now.timeIntervalSince(lastWidgetReload) > 60) || now.timeIntervalSince(lastWidgetReload) > 15 * 60 {
            widgetKey = key
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // ---------------------------------------------------------------- launch at login
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// ---------------------------------------------------------------- settings
struct AppSettings: Equatable {
    var accessKey = ""
    var secretKey = ""
    var serial = ""
    var host = "https://api-e.ecoflow.com"
    var intervalSec = 60
    var lowThreshold = 20

    var isComplete: Bool { !accessKey.isEmpty && !secretKey.isEmpty }
    var api: EcoFlowAPI { EcoFlowAPI(accessKey: accessKey, secretKey: secretKey, host: host) }

    static func load() -> AppSettings {
        let d = UserDefaults.standard
        var s = AppSettings()
        s.accessKey = d.string(forKey: "accessKey") ?? ""
        s.secretKey = Keychain.read("secretKey") ?? ""      // the secret key lives in the macOS Keychain
        s.serial = d.string(forKey: "sn") ?? ""
        if let h = d.string(forKey: "host"), !h.isEmpty { s.host = h }
        if d.object(forKey: "intervalSec") != nil { s.intervalSec = max(10, d.integer(forKey: "intervalSec")) }
        if d.object(forKey: "lowThreshold") != nil { s.lowThreshold = min(100, max(0, d.integer(forKey: "lowThreshold"))) }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(accessKey, forKey: "accessKey")
        Keychain.write("secretKey", secretKey)
        d.set(serial, forKey: "sn")
        d.set(host, forKey: "host")
        d.set(intervalSec, forKey: "intervalSec")
        d.set(lowThreshold, forKey: "lowThreshold")
    }
}

enum Keychain {
    private static let service = "EcoFlowTray"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
