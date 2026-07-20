import Foundation
import WidgetKit

/// Puente app → widget: snapshot de próximos envíos en el App Group.
/// El widget NO hace red ni toca el Keychain — solo lee este JSON.
enum WidgetBridge {
    // Formato "group.…" en ambas plataformas: es el único que el portal de Apple registra,
    // y autorizado vía provisioning profile no dispara el prompt de macOS 15.
    static let suiteName = "group.com.sebastianov.crona"
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
