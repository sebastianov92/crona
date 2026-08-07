import SwiftUI

/// Tarjeta de "primeros pasos" que aparece hasta que el usuario conectó WhatsApp y programó su
/// primer mensaje. Se oculta sola al completar ambos pasos.
struct OnboardingChecklist: View {
    @Environment(SessionStore.self) private var session
    let onConnect: () -> Void
    let onCompose: () -> Void

    private var hasInstance: Bool { session.instances.contains { $0.status == .CONNECTED } }
    private var hasScheduled: Bool { !session.upcoming.isEmpty || !session.history.isEmpty }
    var allDone: Bool { hasInstance && hasScheduled }

    var body: some View {
        if !allDone {
            VStack(alignment: .leading, spacing: 12) {
                Text("Primeros pasos").font(.headline)
                step(done: hasInstance,
                     title: "Conecta tu WhatsApp",
                     subtitle: "Escanea el QR para vincular tu número.",
                     enabled: !hasInstance,
                     action: onConnect)
                step(done: hasScheduled,
                     title: "Programa tu primer mensaje",
                     subtitle: hasInstance ? "Elige contacto, escribe y fija fecha y hora." : "Primero conecta tu WhatsApp.",
                     enabled: hasInstance && !hasScheduled,
                     action: onCompose)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.2)))
            .padding(.horizontal)
            .padding(.top, 6)
            .task { await session.refreshHistory() }   // detecta si ya programó algo que ya se envió
        }
    }

    private func step(done: Bool, title: String, subtitle: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .strikethrough(done)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if enabled { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
