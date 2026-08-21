import Foundation
import UserNotifications

/// Notificaciones locales en iOS y macOS (§9.4).
///
/// Se usa UNUserNotificationCenter LOCAL, que no requiere APNs ni cuenta de pago
/// (push remoto sí exigiría el Apple Developer Program y la capability Push Notifications,
/// prohibida por CLAUDE.md al firmar con Personal Team).
///
/// Dos mecanismos:
/// 1. **Programadas**: al cambiar la lista de pendientes se re-programa una notificación local
///    por mensaje futuro. Se disparan aunque la app esté cerrada — es lo que sustituye a ntfy
///    para el aviso "tu mensaje se está enviando".
/// 2. **En vivo**: mientras la app corre, el WebSocket avisa de envíos, fallos y desconexiones.
@MainActor
enum LocalNotifications {
    /// iOS permite máximo 64 notificaciones locales pendientes por app.
    private static let maxScheduled = 60
    private static let scheduledPrefix = "crona.scheduled."
    private static var observers: [NSObjectProtocol] = []

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "localNotifications") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "localNotifications")
            if !newValue { clearScheduled() }
        }
    }

    static func setup() {
        guard observers.isEmpty else { return }
        requestAuthorization()

        observers.append(NotificationCenter.default.addObserver(
            forName: .cronaLogUpdated, object: nil, queue: .main
        ) { note in
            guard enabled, let log = note.object as? MessageLog else { return }
            if log.status == .SENT {
                post(title: "Mensaje enviado", body: "Tu mensaje programado salió correctamente.")
            } else if log.status == .FAILED, let err = log.error {
                post(title: "Mensaje fallido", body: err)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .cronaInstanceUpdated, object: nil, queue: .main
        ) { note in
            guard enabled, let inst = note.object as? Instance, inst.status == .DISCONNECTED else { return }
            post(title: "WhatsApp desconectado",
                 body: "Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR.")
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .cronaChatIncoming, object: nil, queue: .main
        ) { note in
            guard enabled, let jid = note.userInfo?["jid"] as? String else { return }
            let who = jid.split(separator: "@").first.map(String.init) ?? "un contacto"
            post(title: "Mensaje recibido", body: "Te escribió \(who).")
        })
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Notificaciones programadas (funcionan con la app cerrada)

    /// Re-programa las notificaciones locales de los mensajes pendientes.
    /// Se llama cada vez que cambia la lista de próximos envíos.
    static func reschedule(upcoming: [ScheduledMessage]) {
        clearScheduled()
        guard enabled else { return }

        let center = UNUserNotificationCenter.current()
        let future = upcoming
            .filter { $0.status == .ACTIVE && $0.nextRunAt > Date().addingTimeInterval(30) }
            .sorted { $0.nextRunAt < $1.nextRunAt }
            .prefix(maxScheduled)

        for msg in future {
            let content = UNMutableNotificationContent()
            content.title = "Enviando a \(msg.recipientName)"
            content.body = messagePreview(type: msg.type, body: msg.body)
            content.sound = .default

            let interval = msg.nextRunAt.timeIntervalSinceNow
            guard interval > 0 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let req = UNNotificationRequest(identifier: scheduledPrefix + msg.id, content: content, trigger: trigger)
            center.add(req)
        }
    }

    private static func clearScheduled() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(scheduledPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Aviso inmediato

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
