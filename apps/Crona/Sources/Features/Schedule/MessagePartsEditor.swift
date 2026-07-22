import SwiftUI

/// Parte editable de un mensaje con split. Cada parte mide su PROPIO tiempo de redacción:
/// el worker muestra "escribiendo…" ese rato antes de enviarla.
struct PartDraft: Identifiable, Equatable {
    let id = UUID()
    var text: String = ""
    /// Instante del primer carácter escrito en ESTA parte.
    var typingStart: Date?
    /// Tiempo que traía la plantilla; se conserva si el usuario no reescribe la parte.
    var presetTypingMs: Int?

    init(text: String = "", presetTypingMs: Int? = nil) {
        self.text = text
        self.presetTypingMs = presetTypingMs
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Se llama en cada cambio de texto para arrancar el cronómetro de esta parte.
    mutating func noteTyping() {
        if typingStart == nil && !text.isEmpty { typingStart = .now }
    }

    /// Lo medido, o lo que traía la plantilla si es mayor. Acotado 1.5–25 s.
    var typingMs: Int? {
        let measured = typingStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let raw = max(measured, presetTypingMs ?? 0)
        return raw > 0 ? clampTypingMs(raw) : nil
    }

    var templatePart: TemplatePart { TemplatePart(body: trimmed, typingMs: typingMs) }
}

func clampTypingMs(_ ms: Int) -> Int { max(1500, min(25_000, ms)) }

/// Editor de las partes de un split: un campo por parte, con quitar y "Agregar otro mensaje".
struct PartsEditor: View {
    @Binding var parts: [PartDraft]
    var minParts: Int = 1
    var maxParts: Int = 10
    var placeholder: String = "Escribe un mensaje"
    var addLabel: String = "Agregar otro mensaje"

    var body: some View {
        ForEach($parts) { $part in
            HStack(alignment: .top, spacing: 8) {
                TextField(placeholder, text: $part.text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .onChange(of: part.text) { _, _ in $part.wrappedValue.noteTyping() }
                if canRemove(part) {
                    Button {
                        parts.removeAll { $0.id == part.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Quitar este mensaje")
                }
            }
        }
        if parts.count < maxParts {
            Button {
                parts.append(PartDraft())
            } label: {
                Label(addLabel, systemImage: "plus.circle")
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func canRemove(_ part: PartDraft) -> Bool {
        guard parts.count > minParts else { return false }
        // con mínimo 1, la primera parte no se quita: es el mensaje en sí
        if minParts > 0, parts.first?.id == part.id { return false }
        return true
    }
}

/// Selector de plantillas: al elegir una se copian sus partes; editarlas no toca la plantilla.
struct TemplatePickerSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let kind: TemplateKind
    let onPick: ([TemplatePart]) -> Void

    @State private var templates: [MessageTemplate] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty && !loading {
                    ContentUnavailableView(
                        "Sin plantillas",
                        systemImage: "doc.text",
                        description: Text("Crea plantillas desde Ajustes → Plantillas.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }
                ForEach(templates) { tpl in
                    Button {
                        onPick(tpl.parts)
                        dismiss()
                    } label: {
                        TemplateRow(template: tpl, isMine: tpl.ownerId == session.user?.id)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Plantillas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .task {
                templates = (try? await APIClient.shared.templates(kind: kind).items) ?? []
                loading = false
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}

struct TemplateRow: View {
    let template: MessageTemplate
    let isMine: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: template.parts.count > 1 ? "rectangle.stack" : "text.bubble")
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.body)
                Text(template.parts.first?.body ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if template.parts.count > 1 || !isMine {
                    HStack(spacing: 8) {
                        if template.parts.count > 1 {
                            Text("\(template.parts.count) mensajes")
                        }
                        if !isMine, let owner = template.ownerName {
                            Text("de \(owner)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if template.isPublic {
                Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
