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

// MARK: - Compose: partes homogéneas de cualquier tipo

/// Una parte del compose. A diferencia de PartDraft (solo texto), puede ser de cualquier tipo:
/// texto, foto/video (con caption opcional), nota de voz o sticker. El orden se respeta al enviar.
struct ComposePart: Identifiable, Equatable {
    let id = UUID()

    enum Kind: Equatable {
        case text          // solo texto
        case photoVideo    // imagen o video, con caption de texto opcional
        case audio         // nota de voz (sin texto)
        case sticker       // sticker (sin texto)
    }

    var kind: Kind
    /// Texto de la parte, o caption de la foto/video. Vacío en audio/sticker.
    var text: String = ""
    /// Instante del primer carácter escrito en ESTA parte (mide "escribiendo…").
    var typingStart: Date?
    /// Tiempo que traía la plantilla; se conserva si el usuario no reescribe la parte.
    var presetTypingMs: Int?
    /// Adjunto de la parte (foto/video, audio o sticker).
    var attachment: Attachment?
    /// Duración de la grabación en ms (solo audio) — alimenta "grabando audio…".
    var durationMs: Int?
    /// Foto: enviar como archivo (documento) para que WhatsApp no la recomprima.
    var asFile: Bool = false

    /// Valor corto por defecto de "escribiendo…" para partes de solo media sin texto.
    static let defaultMediaTypingMs = 2000

    init(kind: Kind = .text, text: String = "", presetTypingMs: Int? = nil,
         attachment: Attachment? = nil, durationMs: Int? = nil) {
        self.kind = kind
        self.text = text
        self.presetTypingMs = presetTypingMs
        self.attachment = attachment
        self.durationMs = durationMs
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// ¿Lleva campo de texto editable? (texto propio, o caption de foto/video)
    var hasTextField: Bool { kind == .text || kind == .photoVideo }

    /// ¿Esta parte tiene contenido suficiente para enviarse?
    var isSendable: Bool {
        switch kind {
        case .text: return !trimmed.isEmpty
        case .photoVideo, .audio, .sticker: return attachment != nil
        }
    }

    /// El MessageType que viaja al servidor para esta parte.
    var messageType: MessageType {
        switch kind {
        case .text: return .TEXT
        // como archivo → documento: WhatsApp no lo recomprime (calidad original)
        case .photoVideo: return asFile ? .DOCUMENT : (attachment?.messageType ?? .IMAGE)
        case .audio: return .AUDIO
        case .sticker: return .STICKER
        }
    }

    /// Cuerpo de texto que viaja al servidor (nil en audio/sticker o caption vacío).
    var bodyText: String? {
        guard hasTextField else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Arranca el cronómetro de redacción de esta parte al primer carácter.
    mutating func noteTyping() {
        if typingStart == nil && !text.isEmpty { typingStart = .now }
    }

    /// typingMs por parte, acotado 1.5–25 s:
    /// - texto: tiempo real de redacción de ESTA parte
    /// - foto/video: tiempo de redactar el caption, o un valor corto por defecto
    /// - audio: duración de la grabación
    /// - sticker: valor corto por defecto
    var typingMs: Int? {
        switch kind {
        case .text:
            let measured = typingStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            let raw = max(measured, presetTypingMs ?? 0)
            return raw > 0 ? clampTypingMs(raw) : nil
        case .photoVideo:
            let measured = typingStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            let raw = max(measured, presetTypingMs ?? 0)
            return clampTypingMs(raw > 0 ? raw : Self.defaultMediaTypingMs)
        case .audio:
            return clampTypingMs(durationMs ?? Self.defaultMediaTypingMs)
        case .sticker:
            return clampTypingMs(Self.defaultMediaTypingMs)
        }
    }
}

/// Editor unificado de las partes del compose: una fila por parte, en orden, con quitar.
/// El botón "+" para agregar partes vive en el ComposeView (necesita los pickers).
struct ComposePartsEditor: View {
    @Binding var parts: [ComposePart]
    /// El ComposeView pide enfocar una parte concreta (p.ej. al agregar una de texto).
    @Binding var focusRequest: UUID?
    /// Proxy del ScrollViewReader que envuelve al Form: sube la parte activa sobre el teclado.
    let scrollProxy: ScrollViewProxy

    @FocusState private var focused: UUID?

    var body: some View {
        ForEach($parts) { $part in
            ComposePartRow(part: $part,
                           canRemove: parts.count > 1,
                           focused: $focused,
                           scrollProxy: scrollProxy) {
                parts.removeAll { $0.id == part.id }
            }
            .id(part.id) // ancla para scrollTo: el cursor nunca queda tapado por el teclado
        }
        // Al enfocar una parte, desplázala justo por encima del teclado (la barra de acciones
        // va fija abajo con safeAreaInset, así que basta con dejar ver el cursor).
        .onChange(of: focused) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollProxy.scrollTo(id, anchor: .bottom)
            }
        }
        // El ComposeView pide foco tras agregar una parte de texto.
        .onChange(of: focusRequest) { _, req in
            if let req { focused = req; focusRequest = nil }
        }
    }
}

/// Fila de una parte del compose: pinta el editor según el tipo y ofrece quitar.
private struct ComposePartRow: View {
    @Binding var part: ComposePart
    let canRemove: Bool
    @FocusState.Binding var focused: UUID?
    let scrollProxy: ScrollViewProxy
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                switch part.kind {
                case .text:
                    textField(placeholder: "Escribe un mensaje")
                case .photoVideo:
                    ComposeAttachmentThumb(attachment: part.attachment)
                    textField(placeholder: "Añade un texto (opcional)")
                    // solo para fotos (no video): enviarla como archivo evita la recompresión de WhatsApp
                    if part.attachment?.messageType == .IMAGE {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Enviar como", selection: $part.asFile) {
                                Text("Foto").tag(false)
                                Text("Archivo (HD)").tag(true)
                            }
                            .pickerStyle(.segmented)
                            Text(part.asFile
                                 ? "Como archivo: calidad original, WhatsApp no la recomprime."
                                 : "Como foto: WhatsApp puede reducir la calidad.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                    }
                case .audio:
                    audioRow
                case .sticker:
                    ComposeAttachmentThumb(attachment: part.attachment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quitar esta parte")
            }
        }
    }

    /// Campo de texto acotado a 5 líneas: más allá scrollea por dentro mostrando la última línea
    /// (el cursor), en vez de crecer sin fin y quedar tapado por el teclado.
    private func textField(placeholder: String) -> some View {
        TextField(placeholder, text: $part.text, axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .focused($focused, equals: part.id)
            .padding(8)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture { focused = part.id } // toda la burbuja enfoca
            .onChange(of: part.text) { _, _ in
                part.noteTyping()
                // mientras escribes, mantén el cursor visible sobre el teclado
                if focused == part.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(part.id, anchor: .bottom)
                    }
                }
            }
    }

    private var audioRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nota de voz").font(.body)
                if let ms = part.durationMs {
                    Text(durationLabel(ms)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func durationLabel(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Miniatura de solo lectura para foto/video/sticker dentro de una parte del compose.
/// (Sin botón de cerrar: la parte se quita con el "-" de la fila.)
private struct ComposeAttachmentThumb: View {
    let attachment: Attachment?

    var body: some View {
        if let attachment {
            Group {
                if (attachment.messageType == .IMAGE || attachment.messageType == .STICKER),
                   let img = platformImage(attachment.data) {
                    img.resizable()
                        .aspectRatio(contentMode: attachment.messageType == .STICKER ? .fit : .fill)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: attachment.messageType == .VIDEO ? "video.fill"
                              : attachment.messageType == .AUDIO ? "waveform" : "doc.fill")
                            .font(.title2)
                        Text(attachment.fileName).font(.caption2).lineLimit(1)
                        Text(sizeLabel(attachment)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .frame(width: 120, height: 90)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sizeLabel(_ a: Attachment) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
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
