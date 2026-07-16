#if os(macOS)
import SwiftUI

/// Menu bar (§9.4): próximos 5 envíos + Nuevo mensaje + estado de instancia.
struct MenuBarView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let inst = session.activeInstance {
                HStack(spacing: 6) {
                    Circle()
                        .fill(inst.status == .CONNECTED ? Theme.accent : .red)
                        .frame(width: 8, height: 8)
                    Text("\(inst.name): \(inst.status == .CONNECTED ? "conectado" : "desconectado")")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Divider()
            }

            if session.upcoming.isEmpty {
                Text("No tienes mensajes programados.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ForEach(session.upcoming.prefix(5)) { msg in
                    HStack {
                        Text(msg.recipientName).lineLimit(1)
                        Spacer()
                        Text(scheduleLabel(msg.nextRunAt))
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                }
            }

            Divider()
            Button("Nuevo mensaje") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .catchappNewMessage, object: nil)
            }
            .padding(.horizontal, 12)
            Button("Salir") { NSApp.terminate(nil) }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 260)
    }
}

extension Notification.Name {
    static let catchappNewMessage = Notification.Name("catchapp.new.message")
}
#endif
