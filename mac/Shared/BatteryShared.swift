// Shared between the menu bar app and the widget extension:
// the battery snapshot model, EcoFlow key parsing and the App Group store.

import Foundation

struct BatterySnapshot: Codable, Equatable {
    var name: String
    var soc: Int
    var wattsIn: Int?
    var wattsOut: Int?
    var chargeMin: Int?
    var dischargeMin: Int?
    var charging: Bool
    var live: Bool          // true — from the MQTT stream, false — cloud cache snapshot (may be stale)
    var online: Bool
    var updated: Date

    static let sample = BatterySnapshot(name: "RIVER 2 Pro", soc: 85, wattsIn: 660, wattsOut: 72,
                                        chargeMin: 25, dischargeMin: nil, charging: true,
                                        live: true, online: true, updated: Date())

    // Builds a snapshot from a flat dictionary of EcoFlow parameters. Two key families are supported:
    //  - River 2 / Delta 2 generation: prefixed keys like "pd.soc", "inv.inputWatts", "bms_emsStatus.chgRemainTime";
    //  - Delta 3 / Delta Pro 3 / River 3 generation: flat keys like "cmsBattSoc", "powInSumW", "cmsChgRemTime".
    static func from(_ q: [String: Any], name: String, live: Bool, online: Bool = true) -> BatterySnapshot? {
        guard let soc = int(q, "pd.soc", "cmsBattSoc", "bms_bmsStatus.soc", "bmsBattSoc",
                            "bms_emsStatus.lcdShowSoc", "bms_emsStatus.f32LcdShowSoc") else { return nil }
        let out = int(q, "pd.wattsOutSum", "powOutSumW", "inv.outputWatts")
        var inW = int(q, "pd.wattsInSum", "powInSumW")
        if inW == nil {
            // River 2 / Delta 2 do not send wattsInSum over MQTT — add up AC input and MPPT input (solar/car)
            let ac = int(q, "inv.inputWatts", "powGetAcIn"), dc = int(q, "mppt.inWatts", "powGetPv")
            if ac != nil || dc != nil { inW = max(0, ac ?? 0) + max(0, dc ?? 0) }
        }
        var charging: Bool
        if let bIn = int(q, "bms_bmsStatus.inputWatts"), let bOut = int(q, "bms_bmsStatus.outputWatts") {
            charging = bIn > bOut + 5
        } else {
            charging = (inW ?? 0) > 5 && (inW ?? 0) > (out ?? 0) + 5
        }
        if soc >= 100 { charging = false }   // at 100 % it is only trickle charging; mains powers the load directly

        // 5999 min is EcoFlow's placeholder for "not calculated"
        func valid(_ v: Int?) -> Int? { if let v, v > 0, v < 5999 { return v }; return nil }
        let pdRem = int(q, "pd.remainTime")
        let chg = valid(int(q, "bms_emsStatus.chgRemainTime", "cmsChgRemTime", "bmsChgRemTime"))
            ?? (pdRem.map { $0 > 0 ? $0 : nil } ?? nil)
        let dsg = valid(int(q, "bms_emsStatus.dsgRemainTime", "cmsDsgRemTime", "bmsDsgRemTime"))
            ?? (pdRem.map { $0 < -1 ? -$0 : nil } ?? nil)

        return BatterySnapshot(name: name, soc: soc, wattsIn: inW, wattsOut: out,
                               chargeMin: chg, dischargeMin: dsg, charging: charging,
                               live: live, online: online, updated: Date())
    }

    static func int(_ d: [String: Any], _ keys: String...) -> Int? {
        for k in keys {
            if let n = d[k] as? NSNumber { return Int(n.doubleValue.rounded()) }
            if let s = d[k] as? String, let x = Double(s) { return Int(x.rounded()) }
        }
        return nil
    }

    var flowText: String {
        guard wattsIn != nil || wattsOut != nil else { return "" }
        return "In \(max(0, wattsIn ?? 0))W  Out \(max(0, wattsOut ?? 0))W"
    }

    var timeText: String {
        if charging, let m = chargeMin { return "full in " + Self.hm(m) }
        if !charging, let m = dischargeMin { return Self.hm(m) + " left" }
        if !charging, wattsOut == 0 { return "no load" }
        return ""
    }

    static func hm(_ min: Int) -> String { String(format: "%dh %02dm", min / 60, min % 60) }

    // SF Symbol for the current level
    var symbolName: String {
        if charging { return "battery.100percent.bolt" }
        switch soc {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

// The app writes the latest snapshot into the shared App Group container; the widget reads it.
enum SharedStore {
    // "<TEAMID>.ecoflowtray.shared" — filled in from Info.plist (see project.yml)
    static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "EcoFlowAppGroup") as? String }

    static var fileURL: URL? {
        guard let id = groupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return dir.appendingPathComponent("battery.json")
    }

    static func save(_ s: BatterySnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> BatterySnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BatterySnapshot.self, from: data)
    }
}
