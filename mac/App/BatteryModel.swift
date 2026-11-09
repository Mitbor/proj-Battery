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
    @Published var liveError: String?        // why there is no live stream right now (shown under the cloud cache data)

    private let liveStaleSec: TimeInterval = 120
    private var live: [String: Any] = [:]
    private var lastLive = Date.distantPast
    private var liveStarted = Date.distantPast   // when the current MQTT session was opened
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
        live = [:]; lastLive = .distantPast; reconnectDelay = 5; liveStarted = .distantPast
        guard settings.isComplete else { status = "Open Settings and enter your EcoFlow keys"; return }
        status = "Connecting…"
        liveError = "Connecting to the live stream…"
        Task { await fetchSnapshot() }
        connectLive()
    }

    // "Refresh now": re-reads the cloud snapshot and reconnects the live stream.
    // While the live stream works the data is already current, so there is nothing to do.
    func refreshNow() {
        guard settings.isComplete, !liveFresh else { return }
        restart()
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
        if lastLive == .distantPast && liveStarted != .distantPast
            && Date().timeIntervalSince(liveStarted) > liveStaleSec {
            // connected (or still connecting) but the station never sent anything — try again
            liveStarted = .distantPast
            feed?.stop(); feed = nil
            liveClosed("the station sent no live data for \(Int(liveStaleSec)) s (is it switched on and online?)", gen: generation)
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
                AppLog.write("MQTT: cert fields \(cert.keys.sorted()), broker \(host):\(port), protocol \(cert["protocol"] ?? "-"), " +
                             "account \(user.prefix(6))… (\(user.count) chars), password \(pass.count) chars, " +
                             "client id \(Self.mqttClientId(account: user).count) chars, sn \(sn)")

                let f = MQTTFeed()
                f.onParams = { [weak self] p in
                    Task { @MainActor in self?.ingest(p, gen: gen) }
                }
                f.onClosed = { [weak self] reason in
                    Task { @MainActor in self?.liveClosed(reason, gen: gen) }
                }
                f.onSubscribed = { [weak self] in
                    Task { @MainActor in
                        guard let self, gen == self.generation, !self.liveFresh else { return }
                        self.liveError = "Connected, waiting for data from the station…"
                    }
                }
                feed = f
                liveStarted = Date()
                f.connect(host: host, port: port, user: user, password: pass,
                          clientId: Self.mqttClientId(account: user), topic: "/open/\(user)/\(sn)/quota")
            } catch {
                liveClosed(error.localizedDescription, gen: gen)
            }
        }
    }

    // EcoFlow limits how many distinct MQTT client IDs one account may use; once the limit is hit the broker
    // answers CONNACK code 5 ("not authorized"). So the client ID is generated once and reused forever.
    private static func mqttClientId(account: String) -> String {
        let d = UserDefaults.standard
        let id: String
        if let saved = d.string(forKey: "mqttClientSuffix"), !saved.isEmpty {
            id = saved
        } else {
            id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
            d.set(id, forKey: "mqttClientSuffix")
        }
        return account + "_mac_" + id
    }

    private func liveClosed(_ reason: String, gen: Int) {
        guard gen == generation else { return }
        AppLog.write("MQTT: " + reason)
        if !liveFresh { status = "No live data: \(reason)" }
        liveError = "No live data: \(reason)"
        liveStarted = .distantPast           // the "silent session" check restarts with the next connection
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
        liveError = nil
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
