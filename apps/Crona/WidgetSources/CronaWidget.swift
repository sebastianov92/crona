import WidgetKit
import SwiftUI

// Espejo mínimo del snapshot que escribe la app (WidgetBridge) — sin red, sin Keychain.
struct SnapshotItem: Codable, Identifiable {
    let name: String
    let date: Date
    let recurring: Bool
    var id: String { "\(name)-\(date.timeIntervalSince1970)" }
}

func loadSnapshot() -> [SnapshotItem] {
    guard let defaults = UserDefaults(suiteName: "group.com.sebastian.crona.LV837U84N9"),
          let data = defaults.data(forKey: "upcomingSnapshot"),
          let items = try? JSONDecoder().decode([SnapshotItem].self, from: data) else { return [] }
    return items.filter { $0.date > .now.addingTimeInterval(-60) }.sorted { $0.date < $1.date }
}

struct Entry: TimelineEntry {
    let date: Date
    let items: [SnapshotItem]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, items: [
            SnapshotItem(name: "Mamá", date: .now.addingTimeInterval(3600), recurring: false),
            SnapshotItem(name: "Familia", date: .now.addingTimeInterval(7200), recurring: true),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, items: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let items = loadSnapshot()
        // refrescar cuando pase el próximo envío (o en 30 min si no hay nada)
        let next = items.first.map { max($0.date.addingTimeInterval(60), .now.addingTimeInterval(60)) }
            ?? .now.addingTimeInterval(1800)
        completion(Timeline(entries: [Entry(date: .now, items: items)], policy: .after(next)))
    }
}

let widgetAccent = Color(red: 0.145, green: 0.827, blue: 0.400) // #25D366

func widgetTimeLabel(_ date: Date) -> String {
    let cal = Calendar.current
    let df = DateFormatter()
    df.locale = Locale(identifier: "es")
    if cal.isDateInToday(date) { df.dateFormat = "h:mm a"; return df.string(from: date) }
    if cal.isDateInTomorrow(date) { df.dateFormat = "h:mm a"; return "Mañana " + df.string(from: date) }
    df.dateFormat = "EEE h:mm a"
    return df.string(from: date)
}

struct CronaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var maxRows: Int { family == .systemSmall ? 2 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(widgetAccent)
                Text("Próximos envíos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if entry.items.isEmpty {
                Spacer()
                Text("Nada programado")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(entry.items.prefix(maxRows)) { item in
                    HStack(spacing: 4) {
                        if item.recurring {
                            Image(systemName: "repeat").font(.caption2).foregroundStyle(widgetAccent)
                        }
                        Text(item.name)
                            .font(family == .systemSmall ? .caption : .footnote)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(widgetTimeLabel(item.date))
                            .font(.caption2)
                            .foregroundStyle(widgetAccent)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct CronaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CronaUpcoming", provider: Provider()) { entry in
            CronaWidgetView(entry: entry)
        }
        .configurationDisplayName("Próximos envíos")
        .description("Tus siguientes mensajes programados de WhatsApp.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CronaWidgetBundle: WidgetBundle {
    var body: some Widget {
        CronaWidget()
    }
}
