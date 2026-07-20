import Foundation
import WidgetKit

/// Puente app → widget: snapshot de próximos envíos en el App Group.
/// El widget NO hace red ni toca el Keychain — solo lee este JSON.
enum WidgetBridge {
    // macOS exige prefijo de Team ID (sin él, macOS 15+ pregunta "access data from other apps"
    // en cada arranque); iOS exige prefijo "group.". Formatos distintos por plataforma.
    #if os(macOS)
    static let suiteName = "LV837U84N9.group.com.sebastian.crona"
    #else
    static let suiteName = "group.com.sebastian.crona.LV837U84N9"
    #endif
    static let key = "upcomingSnapshot"

    struct Item: Codable {
        let name: String
        let date: Date
        let recurring: Bool
    }

    static func publish(upcoming: [ScheduledMessage]) {
        let items = upcoming
            .filter { $0.status == .ACTIVE }
            .prefix(6)
            .map { Item(name: $0.recipientName, date: $0.nextRunAt, recurring: $0.recurrence != .NONE) }
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(Array(items)) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
