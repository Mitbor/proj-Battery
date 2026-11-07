// Desktop / Notification Center widget. It shows the snapshot the menu bar app saved
// into the shared App Group container; the app asks macOS to refresh the widget when the level changes.

import WidgetKit
import SwiftUI

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: BatterySnapshot?
}

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: Date(), snapshot: SharedStore.load() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let entry = BatteryEntry(date: Date(), snapshot: SharedStore.load())
        // the app triggers reloads on changes; this is just a safety net
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct BatteryWidgetView: View {
    let entry: BatteryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemMedium: medium(s)
            default: small(s)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "battery.0percent").font(.title)
                Text("Open EcoFlow Tray and enter your keys").font(.caption).multilineTextAlignment(.center)
            }
        }
    }

    private var stale: Bool { entry.snapshot.map { Date().timeIntervalSince($0.updated) > 10 * 60 } ?? true }

    private func color(_ s: BatterySnapshot) -> Color {
        if !s.online || stale { return .gray }
        if s.charging { return .blue }
        if s.soc <= 20 { return .red }
        if s.soc <= 50 { return .orange }
        return .green
    }

    private func updatedText(_ s: BatterySnapshot) -> Text {
        Text("updated ") + Text(s.updated, style: .time)
    }

    private func small(_ s: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if s.charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(s.soc)").font(.system(size: 40, weight: .semibold, design: .rounded))
                Text("%").font(.title3).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(100, max(0, s.soc))), total: 100).tint(color(s))
            Spacer(minLength: 0)
            if !s.timeText.isEmpty { Text(s.timeText).font(.caption2).lineLimit(1) }
            updatedText(s).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func medium(_ s: BatterySnapshot) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 10)
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, s.soc))) / 100)
                    .stroke(color(s), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(s.soc)%").font(.system(size: 24, weight: .semibold, design: .rounded))
                    if s.charging { Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.yellow) }
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 6) {
                Text(s.name).font(.headline).lineLimit(1)
                if !s.flowText.isEmpty { Text(s.flowText).font(.callout) }
                if !s.timeText.isEmpty { Text(s.timeText).font(.callout).foregroundStyle(.secondary) }
                if !s.online { Text("Station is offline").font(.caption).foregroundStyle(.red) }
                updatedText(s).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

@main
struct EcoFlowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EcoFlowWidget", provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("EcoFlow Battery")
        .description("Charge level of your EcoFlow power station.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
