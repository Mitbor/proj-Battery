// EcoFlow power station (River 2, Delta 2, Delta 3 ...) — battery level in the macOS menu bar,
// plus a desktop / Notification Center widget fed by this app.

import SwiftUI
import AppKit

@main
struct EcoFlowTrayApp: App {
    @StateObject private var model = BatteryModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("EcoFlow Tray Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        if let s = snapshot {
            HStack(spacing: 3) {
                Image(systemName: s.symbolName)
                Text("\(s.soc)%")
            }
        } else {
            Image(systemName: "battery.0percent")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: BatteryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = model.snapshot {
                HStack {
                    Text(s.name).font(.headline)
                    Spacer()
                    if s.charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(s.soc)").font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("%").font(.title3).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(min(100, max(0, s.soc))), total: 100)
                    .tint(levelColor(s, low: model.settings.lowThreshold))
                if !s.flowText.isEmpty { Text(s.flowText) }
                if !s.timeText.isEmpty { Text(s.timeText).foregroundStyle(.secondary) }
                Text(s.live ? "Updated \(s.updated.formatted(date: .omitted, time: .standard))" : model.status)
                    .font(.caption).foregroundStyle(.secondary)
                if !s.live, let e = model.liveError {
                    Text(e).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.status).foregroundStyle(.secondary)
            }

            Divider()

            Button {
                model.refreshNow()
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
            }
            .disabled(!model.settings.isComplete || model.liveFresh)
            .help(model.liveFresh ? "Live data is already arriving every few seconds" : "Re-read the cloud and reconnect the live stream")

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

func levelColor(_ s: BatterySnapshot, low: Int) -> Color {
    if !s.online { return .gray }
    if s.charging { return .blue }
    if s.soc <= low { return .red }
    if s.soc <= 50 { return .orange }
    return .green
}

struct SettingsView: View {
    @ObservedObject var model: BatteryModel
    @State private var draft = AppSettings()
    @State private var message = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Text("Get your keys at developer.ecoflow.com → Become a Developer → Access Key / Secret Key (sign in with the same account as in the EcoFlow app).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Open developer.ecoflow.com", destination: URL(string: "https://developer.ecoflow.com/us/security")!)

            TextField("Access Key", text: $draft.accessKey)
            SecureField("Secret Key", text: $draft.secretKey)
            HStack {
                TextField("Serial number", text: $draft.serial)
                Button("Find") { Task { await findDevices() } }.disabled(busy)
            }
            Picker("Server", selection: $draft.host) {
                Text("Europe — api-e.ecoflow.com").tag("https://api-e.ecoflow.com")
                Text("Americas — api-a.ecoflow.com").tag("https://api-a.ecoflow.com")
                Text("Global — api.ecoflow.com").tag("https://api.ecoflow.com")
            }
            Stepper("Fallback poll: \(draft.intervalSec) s", value: $draft.intervalSec, in: 10...3600, step: 10)
            Stepper("Warn at: \(draft.lowThreshold) %", value: $draft.lowThreshold, in: 0...100, step: 5)

            Text("Leave the serial number empty to use the first power station on the account.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.accessKey = draft.accessKey.trimmingCharacters(in: .whitespaces)
                    draft.secretKey = draft.secretKey.trimmingCharacters(in: .whitespaces)
                    draft.serial = draft.serial.trimmingCharacters(in: .whitespaces)
                    guard draft.isComplete else { message = "Enter the Access Key and Secret Key."; return }
                    model.apply(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { draft = model.settings }
    }

    private func findDevices() async {
        guard draft.isComplete else { message = "Enter the Access Key and Secret Key first."; return }
        busy = true; defer { busy = false }
        do {
            let devs = try await draft.api.listDevices()
            guard !devs.isEmpty else { message = "No devices found."; return }
            let lines = devs.map { d in
                "\(d["sn"] ?? "") — \(d["productName"] ?? d["deviceName"] ?? "")" +
                ("\(d["online"] ?? "")" == "1" ? " (online)" : " (offline)")
            }
            let pick = devs.first(where: EcoFlowAPI.isStation) ?? devs[0]
            draft.serial = "\(pick["sn"] ?? "")"
            message = "Found:\n" + lines.joined(separator: "\n") + "\nSelected: \(draft.serial)"
        } catch {
            message = error.localizedDescription
        }
    }
}
