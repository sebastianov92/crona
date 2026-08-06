import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// CRUD de plantillas. Se ven las propias y las públicas de cualquiera,
/// pero editar es solo del creador (el servidor responde 403 si no).
struct TemplatesView: View {
    @Environment(SessionStore.self) private var session

    var kind: TemplateKind = .MESSAGE

    @State private var templates: [MessageTemplate] = []
    @State private var editing: MessageTemplate?
    @State private var showCreate = false
    @State private var deleting: MessageTemplate?

    private var mine: [MessageTemplate] { templates.filter { $0.ownerId == session.user?.id } }
    private var others: [MessageTemplate] { templates.filter { $0.ownerId != session.user?.id } }

    var body: some View {
        Form {
            Section {
                if mine.isEmpty {
                    Text("Aún no tienes plantillas. Crea una con el botón +.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mine) { tpl in row(tpl, isMine: true) }
            } header: {
                Text("Mis plantillas")
            } footer: {
                Text(kind == .GROUP_INITIAL
                     ? "Se usan como mensaje inicial al crear un grupo."
                     : "Al usarlas se copian al mensaje: editar el texto no cambia la plantilla.")
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { tpl in row(tpl, isMine: false) }
                } header: {
                    Text("Públicas")
                } footer: {
                    Text("Compartidas por otros usuarios. Puedes usarlas, pero solo su creador puede editarlas.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind == .GROUP_INITIAL ? "Plantillas de grupo" : "Plantillas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("Nueva plantilla", systemImage: "plus") }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            TemplateEditView(template: nil, kind: kind)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { tpl in
            TemplateEditView(template: tpl, kind: tpl.kind)
        }
        .alert("¿Eliminar plantilla?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let tpl = deleting { Task { await remove(tpl) } }
                deleting = nil
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: {
            Text("\"\(deleting?.name ?? "")\" dejará de estar disponible.")
        }
    }

    @ViewBuilder
    private func row(_ tpl: MessageTemplate, isMine: Bool) -> some View {
        TemplateRow(template: tpl, isMine: isMine)
            .contentShape(Rectangle())
            .onTapGesture { if isMine { editing = tpl } }
            .swipeActions(edge: .trailing) {
                if isMine || session.isAdmin {
                    Button(role: .destructive) { deleting = tpl } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .contextMenu {
                if isMine { Button("Editar") { editing = tpl } }
                if isMine || session.isAdmin {
                    Button("Eliminar", role: .destructive) { deleting = tpl }
                }
            }
    }

    private func load() async {
        templates = (try? await APIClient.shared.templates(kind: kind).items) ?? []
    }

    private func remove(_ tpl: MessageTemplate) async {
        do {
            _ = try await APIClient.shared.deleteTemplate(id: tpl.id)
            await load()
        } catch { session.report(error) }
    }
}

struct TemplateEditView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let template: MessageTemplate?
    let kind: TemplateKind

    @State private var name = ""
    @State private var isPublic = false
    @State private var parts: [ComposePart] = [ComposePart(kind: .text)]
    @State private var focusRequest: UUID?
    @State private var busy = false
    @State private var uploading = false
    @State private var error: String?

    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif
    @State private var showFileImporter = false
    @State private var showStickerImporter = false
    @State private var showStickerPicker = false
    @State private var showRecorder = false

    private let maxParts = 10
    // Los grupos envían solo texto como mensaje inicial → sin media en plantillas de grupo.
    private var allowsMedia: Bool { kind == .MESSAGE }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parts.contains { $0.isSendable } && !busy
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Nombre") {
                    TextField("Ej. Saludo de bienvenida", text: $name)
                }
                Section {
                    ComposePartsEditor(parts: $parts, focusRequest: $focusRequest, scrollProxy: proxy)
                    if allowsMedia { addPartBar } else { addTextButton }
                    if parts.contains(where: { $0.hasTextField }) {
                        VariableChips { insertVariable($0) }
                        Text("Toca una variable para insertarla; se reemplaza al enviar (ej. {primer_nombre} → Dani).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(parts.count > 1 ? "Partes (\(parts.count))" : "Mensaje")
                } footer: {
                    Text(allowsMedia
                         ? "Combina texto, foto/video, nota de voz y stickers. Cada parte se envía como un mensaje aparte."
                         : "Mensaje inicial del grupo. Cada parte es un mensaje aparte.")
                }
                Section {
                    Toggle("Pública", isOn: $isPublic)
                } footer: {
                    Text("Las plantillas públicas las ven y usan todos los usuarios, pero solo tú puedes editarlas.")
                }
                if uploading { Section { ProgressView("Subiendo archivo…") } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(template == nil ? "Nueva plantilla" : "Editar plantilla")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Guardar") }
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showRecorder) {
                VoiceRecorderSheet { att, durationMs in addPart(ComposePart(kind: .audio, attachment: att, durationMs: durationMs)) }
            }
            .sheet(isPresented: $showStickerPicker) {
                StickerPickerView { att in addPart(ComposePart(kind: .sticker, attachment: att)) }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItem) { _, item in guard let item else { return }; Task { await loadPhoto(item) } }
            #endif
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.jpeg, .png, .webP, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            .fileImporter(isPresented: $showStickerImporter, allowedContentTypes: [.webP, .png, .jpeg]) { result in
                if case .success(let url) = result { loadFile(url, asSticker: true) }
            }
            .onAppear(perform: loadTemplate)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    // MARK: - Barra de partes (igual que el compositor)

    @ViewBuilder private var addPartBar: some View {
        HStack(spacing: 6) {
            partButton("Texto", "text.bubble") { addTextPart() }
            partButton("Foto", "photo") {
                #if os(iOS)
                showPhotoPicker = true
                #else
                showFileImporter = true
                #endif
            }
            partButton("Voz", "mic.fill") { showRecorder = true }
            Menu {
                Button { showStickerPicker = true } label: { Label("Mis stickers", systemImage: "square.grid.2x2") }
                Button { showStickerImporter = true } label: { Label("Desde archivo", systemImage: "face.smiling") }
            } label: { partButtonLabel("Sticker", "face.smiling") }
            .buttonStyle(.plain)
        }
        .disabled(parts.count >= maxParts)
    }

    private var addTextButton: some View {
        Button { addTextPart() } label: {
            Label("Agregar otro mensaje", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(parts.count >= maxParts)
    }

    private func partButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { partButtonLabel(label, icon) }.buttonStyle(.plain)
    }

    private func partButtonLabel(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label).font(.caption2)
        }
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(Theme.accent).contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func addTextPart() {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty {
            focusRequest = parts[0].id
        } else {
            let p = ComposePart(kind: .text); parts.append(p); focusRequest = p.id
        }
    }

    private func addPart(_ part: ComposePart) {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty, parts[0].attachment == nil {
            parts[0] = part
        } else {
            parts.append(part)
        }
    }

    private func insertVariable(_ v: String) {
        if let i = parts.firstIndex(where: { $0.kind == .text }) {
            if !parts[i].text.isEmpty && !parts[i].text.hasSuffix(" ") { parts[i].text += " " }
            parts[i].text += v
        } else {
            parts.insert(ComposePart(kind: .text, text: v), at: 0)
        }
    }

    #if os(iOS)
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            if let movie = try await item.loadTransferable(type: MovieFile.self) {
                let data = try Data(contentsOf: movie.url)
                addPart(ComposePart(kind: .photoVideo, attachment: Attachment(data: data, fileName: movie.url.lastPathComponent, mimeType: "video/quicktime")))
                try? FileManager.default.removeItem(at: movie.url)
            } else if let data = try await item.loadTransferable(type: Data.self) {
                addPart(ComposePart(kind: .photoVideo, attachment: Attachment(data: uprightImageData(data, mime: "image/jpeg"), fileName: "foto.jpg", mimeType: "image/jpeg")))
            }
            photoItem = nil
        } catch { self.error = "No se pudo cargar el archivo: \(error.localizedDescription)" }
    }
    #endif

    private func loadFile(_ url: URL, asSticker: Bool = false) {
        guard url.startAccessingSecurityScopedResource() else { error = "Sin permiso para leer el archivo."; return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let bytes = asSticker ? data : uprightImageData(data, mime: mime)
            addPart(ComposePart(kind: asSticker ? .sticker : .photoVideo,
                                attachment: Attachment(data: bytes, fileName: url.lastPathComponent, mimeType: mime, asSticker: asSticker)))
        } catch { self.error = "No se pudo leer el archivo: \(error.localizedDescription)" }
    }

    private func composePart(type: MessageType, body: String?, mediaId: String?) -> ComposePart {
        switch type {
        case .TEXT: return ComposePart(kind: .text, text: body ?? "")
        case .IMAGE, .VIDEO, .DOCUMENT:
            var p = ComposePart(kind: .photoVideo, text: body ?? ""); p.existingMediaId = mediaId; p.existingType = type
            if type == .DOCUMENT { p.asFile = true }; return p
        case .AUDIO: var p = ComposePart(kind: .audio); p.existingMediaId = mediaId; p.existingType = type; return p
        case .STICKER: var p = ComposePart(kind: .sticker); p.existingMediaId = mediaId; p.existingType = type; return p
        }
    }

    private func loadTemplate() {
        guard let template else { return }
        name = template.name
        isPublic = template.isPublic
        let rebuilt = template.parts.map { p -> ComposePart in
            var cp = composePart(type: p.type, body: p.body, mediaId: p.mediaId)
            cp.presetTypingMs = p.typingMs
            return cp
        }
        parts = rebuilt.isEmpty ? [ComposePart(kind: .text)] : rebuilt
    }

    private func save() async {
        busy = true; defer { busy = false }
        let sendParts = parts.filter { $0.isSendable }
        do {
            var mediaIds: [UUID: String] = [:]
            let withMedia = sendParts.filter { $0.attachment != nil }
            if !withMedia.isEmpty {
                uploading = true
                for p in withMedia {
                    guard let att = p.attachment else { continue }
                    mediaIds[p.id] = try await APIClient.shared.uploadMedia(data: att.data, fileName: att.fileName, mimeType: att.mimeType).mediaId
                }
                uploading = false
            }
            for p in sendParts where p.attachment == nil { if let mid = p.existingMediaId { mediaIds[p.id] = mid } }
            let payload = sendParts.map { p in
                TemplatePart(type: p.messageType, body: p.bodyText, mediaId: mediaIds[p.id], typingMs: p.typingMs)
            }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            if let template {
                _ = try await APIClient.shared.patchTemplate(id: template.id, name: trimmedName, isPublic: isPublic, parts: payload)
            } else {
                _ = try await APIClient.shared.createTemplate(name: trimmedName, kind: kind, isPublic: isPublic, parts: payload)
            }
            dismiss()
        } catch {
            uploading = false
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
