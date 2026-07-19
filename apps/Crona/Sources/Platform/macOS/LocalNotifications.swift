#if os(macOS)
import Foundation
import UserNotifications

/// Notificaciones locales en macOS (§9.4): enviado/fallido/desconexión mientras la app corre.
/// UNUserNotificationCenter local está permitido sin cuenta de pago (no usa APNs).
@MainActor
enum LocalNotifications {
    private static var observers: [NSObjectProtocol] = []

    static func setup() {
        guard observers.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        observers.append(NotificationCenter.default.addObserver(
            forName: .catchappLogUpdated, object: nil, queue: .main
        ) { note in
            guard let log = note.object as? MessageLog else { return }
            if log.status == .SENT {
                post(title: "Mensaje enviado", body: "Tu mensaje programado salió correctamente.")
            } else if log.status == .FAILED, let err = log.error {
                post(title: "Mensaje fallido", body: err)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .catchappInstanceUpdated, object: nil, queue: .main
        ) { note in
            guard let inst = note.object as? Instance, inst.status == .DISCONNECTED else { return }
            post(title: "WhatsApp desconectado",
                 body: "Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR.")
        })
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
#endif
