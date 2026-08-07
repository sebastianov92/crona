import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Crear un grupo de WhatsApp: ahora mismo o programado. El servidor crea el grupo,
/// le pone la foto y manda el mensaje inicial unos segundos después.
struct CreateGroupView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var instanceId: String?
    @State private var name = ""
    @State private var participants: [Recipient] = []
    // Mensaje inicial con el editor unificado (texto/foto/voz/sticker), igual que al programar.
    @State private var parts: [ComposePart] = [ComposePart(kind: .text)]
    @State private var focusRequest: UUID?

    @State private var pictureMediaId: String?
    @State private var pickedPicture: Data?

    @State private var scheduled = false
    @State private var date = Date().addingTimeInterval(3600)

    @State private var showPicker = false
    @State private var showTemplates = false
    @State private var showFileImporter = false
    // El fileImporter se comparte entre la foto del grupo y una parte del mensaje (macOS).
    private enum FileTarget { case groupPhoto, message }
    @State private var fileTarget: FileTarget = .groupPhoto
    @State private var showRecorder = false
    @State private var showStickerPicker = false
    @State private var uploading = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?          // foto del grupo
    @State private var showPhotoPicker = false
    @State private var msgPhotoItem: PhotosPickerItem?       // foto/video de una parte del mensaje
    @State private var showMsgPhoto = false
    #endif

    @State private var busy = false
    @State private var error: String?
    @State private var created: GroupCreation?
    @State private var confirmNoPhoto = false

    private var hasPhoto: Bool { pickedPicture != nil || pictureMediaId != nil }

    private var canSubmit: Bool {
        instanceId != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !participants.isEmpty && !busy
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if created != nil {
                    resultSection
                } else {
                    formSections(proxy)
                }
            }
            .formStyle(.grouped)
            // Barra de adjuntos fija sobre el teclado, igual que al programar (solo al componer).
            .safeAreaInset(edge: .bottom) {
                if created == nil {
                    addPartBar
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .background(.bar)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            // El grupo se crea en el servidor de forma asíncrona: el WS avisa cuando termina.
            .onReceive(NotificationCenter.default.publisher(for: .cronaGroupUpdated)) { note in
                guard let info = note.userInfo, let gid = info["id"] as? String, gid == created?.id else { return }
                Task { await refreshCreated() }
            }
            .navigationTitle("Crear grupo")
            .alert("Crear el grupo sin foto?", isPresented: $confirmNoPhoto) {
                Button("Crear igual") { Task { await submit() } }
                Button("Elegir foto") {
                    #if os(iOS)
                    showPhotoPicker = true
                    #else
                    showFileImporter = true
                    #endif
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("El grupo se creará sin foto de perfil. Puedes ponérsela después.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancelar" : "Cerrar") { dismiss() }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if hasPhoto { Task { await submit() } } else { confirmNoPhoto = true }
                        } label: {
                            if busy { ProgressView().controlSize(.small) }
                            else { Text(scheduled ? "Programar" : "Crear") }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                if let iid = instanceId ?? session.activeInstance?.id {
                    // allowGroups: false — un grupo no puede ser participante de otro grupo.
                    // El filtro por .CONTACT cubre además las listas, que sí pueden traer grupos.
                    RecipientPickerView(instanceId: iid, startInMulti: true,
                                        preselected: participants, allowGroups: false) { picked in
                        for r in picked where r.kind == .CONTACT
                            && !participants.contains(where: { $0.jid == r.jid }) {
                            participants.append(r)
                        }
                    }
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Cargando tus instancias…").foregroundStyle(.secondary)
                    }
                    .padding(48)
                    .task {
                        await session.refreshInstances()
                        instanceId = session.activeInstance?.id
                    }
                }
            }
            .sheet(isPresented: $showTemplates) {
                TemplatePickerSheet(kind: .GROUP_INITIAL) { tplParts in applyTemplate(tplParts) }
            }
            .sheet(isPresented: $showRecorder) {
                VoiceRecorderSheet { att, durationMs in
                    addPart(ComposePart(kind: .audio, attachment: att, durationMs: durationMs))
                }
            }
            .sheet(isPresented: $showStickerPicker) {
                StickerPickerView { att in addPart(ComposePart(kind: .sticker, attachment: att)) }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    pickedPicture = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                }
            }
            .photosPicker(isPresented: $showMsgPhoto, selection: $msgPhotoItem, matching: .any(of: [.images, .videos]))
            .onChange(of: msgPhotoItem) { _, item in
                guard let item else { return }
                Task { await loadMsgPhoto(item) }
            }
            #endif
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: fileTarget == .groupPhoto ? [.jpeg, .png] : [.image, .movie, .pdf]) { result in
                guard case .success(let url) = result else { return }
                if fileTarget == .groupPhoto {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        pickedPicture = try? Data(contentsOf: url)
                    }
                } else {
                    loadMsgFile(url)
                }
            }
            .onAppear {
                instanceId = instanceId ?? session.activeInstance?.id
                pictureMediaId = session.user?.defaultGroupPictureMediaId
            }
            .onChange(of: session.instances) { _, _ in
                if instanceId == nil { instanceId = session.activeInstance?.id }
            }
            } // ScrollViewReader
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 580)
        #endif
    }

    // MARK: - Formulario

    @ViewBuilder
    private func formSections(_ proxy: ScrollViewProxy) -> some View {
        if session.instances.count > 1 {
            Section("Instancia") {
                Picker("Crear desde", selection: $instanceId) {
                    ForEach(session.instances) { inst in
                        Text(inst.name).tag(Optional(inst.id))
                    }
                }
            }
        }

        Section("Grupo") {
            TextField("Nombre del grupo", text: $name)
            HStack(spacing: 12) {
                GroupPictureView(data: pickedPicture, mediaId: pictureMediaId)
                VStack(alignment: .leading, spacing: 4) {
                    Button("Cambiar foto") {
                        #if os(iOS)
                        showPhotoPicker = true
                        #else
                        fileTarget = .groupPhoto; showFileImporter = true
                        #endif
                    }
                    if pickedPicture != nil || pictureMediaId != nil {
                        Button("Quitar foto", role: .destructive) {
                            pickedPicture = nil
                            pictureMediaId = nil
                        }
                        .font(.caption)
                    }
                }
                Spacer()
            }
        }

        Section("Participantes (\(participants.count))") {
            ForEach(participants, id: \.jid) { r in
                HStack(spacing: 12) {
                    AvatarView(name: r.shownName, pictureUrl: r.pictureUrl, size: 36)
                    Text(r.shownName)
                    Spacer()
                    Button {
                        participants.removeAll { $0.jid == r.jid }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showPicker = true
            } label: {
                Label(participants.isEmpty ? "Elegir participantes" : "Agregar más",
                      systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        Section {
            // Editor unificado (texto/foto/voz/sticker), igual que al programar un mensaje.
            // La barra de adjuntos va fija sobre el teclado (safeAreaInset), no aquí.
            ComposePartsEditor(parts: $parts, focusRequest: $focusRequest, scrollProxy: proxy)
            Button {
                showTemplates = true
            } label: {
                Label("Usar plantilla", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if sendableCount > 1 {
                Text("Se enviarán \(sendableCount) mensajes seguidos, con una pausa corta entre cada uno.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mensaje inicial")
        } footer: {
            Text("Se envía entre 5 y 10 segundos después de crear el grupo. Déjalo vacío si no quieres mensaje.")
        }

        Section {
            Toggle("Programar para después", isOn: $scheduled)
            if scheduled {
                HStack(spacing: 8) {
                    quickChip("Mañana", icon: "sunrise", hours.morning)
                    quickChip("Tarde", icon: "sun.max", hours.afternoon)
                    quickChip("Noche", icon: "moon", hours.evening)
                }
                DatePicker("Fecha y hora", selection: $date, in: Date().addingTimeInterval(120)...)
            }
        } footer: {
            Text(scheduled ? "El grupo se creará a la hora elegida." : "El grupo se crea al instante.")
        }

        if let error {
            Section { Text(error).foregroundStyle(.red) }
        }
    }

    private var hours: QuickHours { session.user?.quickHours ?? .default }

    private func quickChip(_ label: String, icon: String, _ range: QuickRange) -> some View {
        Button {
            date = quickDate(range)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editor del mensaje inicial (texto/foto/voz/sticker)

    private var sendableCount: Int { parts.filter { $0.isSendable }.count }

    @ViewBuilder private var addPartBar: some View {
        HStack(spacing: 6) {
            partButton("Texto", "text.bubble") { addTextPart() }
            partButton("Foto", "photo") {
                #if os(iOS)
                showMsgPhoto = true
                #else
                fileTarget = .message; showFileImporter = true
                #endif
            }
            partButton("Voz", "mic.fill") { showRecorder = true }
            partButton("Sticker", "face.smiling") { showStickerPicker = true }
        }
        .disabled(parts.count >= 10)
    }

    private func partButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Theme.accent)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func addTextPart() {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty {
            focusRequest = parts[0].id
        } else {
            let p = ComposePart(kind: .text); parts.append(p); focusRequest = p.id
        }
    }

    /// Agrega una parte de media; sustituye la única parte si es un texto vacío sin usar.
    private func addPart(_ part: ComposePart) {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty, parts[0].attachment == nil {
            parts[0] = part
        } else {
            parts.append(part)
        }
    }

    #if os(iOS)
    private func loadMsgPhoto(_ item: PhotosPickerItem) async {
        defer { msgPhotoItem = nil }
        if let movie = try? await item.loadTransferable(type: MovieFile.self),
           let data = try? Data(contentsOf: movie.url) {
            addPart(ComposePart(kind: .photoVideo,
                                attachment: Attachment(data: data, fileName: movie.url.lastPathComponent, mimeType: "video/quicktime")))
            try? FileManager.default.removeItem(at: movie.url)
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            addPart(ComposePart(kind: .photoVideo,
                                attachment: Attachment(data: uprightImageData(data, mime: "image/jpeg"), fileName: "foto.jpg", mimeType: "image/jpeg")))
        }
    }
    #endif

    private func loadMsgFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let bytes = mime.hasPrefix("image/") ? uprightImageData(data, mime: mime) : data
        addPart(ComposePart(kind: .photoVideo,
                            attachment: Attachment(data: bytes, fileName: url.lastPathComponent, mimeType: mime)))
    }

    /// Aplica una plantilla al mensaje inicial: reconstruye sus partes (texto reutiliza media por id).
    private func applyTemplate(_ tplParts: [TemplatePart]) {
        let mapped: [ComposePart] = tplParts.map { p in
            switch p.type {
            case .TEXT: return ComposePart(kind: .text, text: p.body ?? "", presetTypingMs: p.typingMs)
            case .AUDIO: var c = ComposePart(kind: .audio); c.existingMediaId = p.mediaId; c.existingType = p.type; return c
            case .STICKER: var c = ComposePart(kind: .sticker); c.existingMediaId = p.mediaId; c.existingType = p.type; return c
            default:
                var c = ComposePart(kind: .photoVideo, text: p.body ?? ""); c.existingMediaId = p.mediaId; c.existingType = p.type; return c
            }
        }
        if !mapped.isEmpty { parts = mapped }
    }

    // MARK: - Resultado

    @ViewBuilder
    private var resultSection: some View {
        if let g = created {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: g.status.systemImage)
                        .font(.title2)
                        .foregroundStyle(g.status.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.name).font(.headline)
                        Text(g.status.label).font(.caption).foregroundStyle(.secondary)
                        if g.status == .PENDING && g.runAt > Date() {
                            Text("Se creará el \(scheduleLabel(g.runAt))")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    Spacer()
                    if g.status == .PENDING || g.status == .CREATING {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let err = g.lastError {
                Section("Error") { Text(err).foregroundStyle(.red) }
            }
        }
    }

    // MARK: - Envío

    private func submit() async {
        guard let instanceId else { return }
        busy = true; defer { busy = false }
        error = nil
        do {
            var mediaId = pictureMediaId
            if let pickedPicture {
                mediaId = try await APIClient.shared.uploadMedia(
                    data: pickedPicture, fileName: "grupo.jpg", mimeType: "image/jpeg").mediaId
            }
            // Mensaje inicial: sube el media de cada parte y arma las partes (texto/foto/voz/sticker).
            let sendParts = parts.filter { $0.isSendable }
            var mediaIds: [UUID: String] = [:]
            let withMedia = sendParts.filter { $0.attachment != nil }
            if !withMedia.isEmpty {
                uploading = true
                for part in withMedia {
                    guard let att = part.attachment else { continue }
                    mediaIds[part.id] = try await APIClient.shared.uploadMedia(
                        data: att.data, fileName: att.fileName, mimeType: att.mimeType).mediaId
                }
                uploading = false
            }
            for part in sendParts where part.attachment == nil {
                if let mid = part.existingMediaId { mediaIds[part.id] = mid }
            }
            let messageParts = sendParts.map { part in
                TemplatePart(type: part.messageType, body: part.bodyText, mediaId: mediaIds[part.id], typingMs: part.typingMs)
            }
            let body = CreateGroupBody(
                instanceId: instanceId,
                name: name.trimmingCharacters(in: .whitespaces),
                pictureMediaId: mediaId,
                participants: participants.map { GroupParticipant(jid: $0.jid, name: $0.shownName) },
                parts: messageParts,
                scheduledAt: scheduled ? date : nil
            )
            created = try await APIClient.shared.createGroup(body)
            if !scheduled { await pollStatus() }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Refresca el estado del grupo recién creado desde el servidor.
    private func refreshCreated() async {
        guard let id = created?.id,
              let items = try? await APIClient.shared.groups().items,
              let fresh = items.first(where: { $0.id == id }) else { return }
        created = fresh
    }

    /// Respaldo del WS: crear grupo + mensaje inicial puede tardar (hasta ~40 s por la señal
    /// "escribiendo…"). Sondea con una ventana amplia; el WS suele adelantar el resultado.
    private func pollStatus() async {
        for _ in 0..<40 {
            if created?.status == .DONE || created?.status == .FAILED { return }
            try? await Task.sleep(for: .seconds(3))
            await refreshCreated()
        }
    }
}

/// Foto del grupo: la recién elegida, la subida por defecto, o un placeholder.
struct GroupPictureView: View {
    let data: Data?
    let mediaId: String?

    @State private var remote: PlatformImage?

    var body: some View {
        Group {
            if let data, let img = PlatformImage(data: data) {
                Image(platform: img).resizable().scaledToFill()
            } else if let remote {
                Image(platform: remote).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.2))
                    Image(systemName: "person.3.fill").foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .task(id: mediaId) {
            guard data == nil, let mediaId else { remote = nil; return }
            remote = await MediaCache.image(for: mediaId)
        }
    }
}

extension GroupCreationStatus {
    var label: String {
        switch self {
        case .PENDING: return "Pendiente"
        case .CREATING: return "Creando…"
        case .DONE: return "Grupo creado"
        case .FAILED: return "Falló"
        }
    }
    var systemImage: String {
        switch self {
        case .PENDING: return "clock"
        case .CREATING: return "hourglass"
        case .DONE: return "checkmark.circle.fill"
        case .FAILED: return "exclamationmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .FAILED: return .red
        case .DONE: return Theme.accent
        default: return .secondary
        }
    }
}

/// Grupos creados y programados, con su estado y el error si falló.
struct GroupsListView: View {
    @Environment(SessionStore.self) private var session
    @State private var groups: [GroupCreation] = []
    @State private var loading = true

    var body: some View {
        List {
            if groups.isEmpty && !loading {
                ContentUnavailableView(
                    "Sin grupos",
                    systemImage: "person.3",
                    description: Text("Aquí aparecen los grupos que creas desde Crona.")
                )
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            ForEach(groups) { g in
                Group {
                    // Grupo ya creado → navega a su gestión (enlace, asunto, participantes).
                    if g.status == .DONE, g.groupJid != nil {
                        NavigationLink { GroupManageView(group: g) } label: { row(g) }
                    } else {
                        row(g)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task {
                            do {
                                _ = try await APIClient.shared.deleteGroup(id: g.id)
                                await load()
                            } catch { session.report(error) }
                        }
                    } label: { Label("Eliminar", systemImage: "trash") }
                    .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && groups.isEmpty { ProgressView() } }
        .navigationTitle("Grupos")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func row(_ g: GroupCreation) -> some View {
        HStack(spacing: 12) {
            GroupPictureView(data: nil, mediaId: g.pictureMediaId)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.headline)
                Text("\(g.participants.count) participantes")
                    .font(.caption).foregroundStyle(.secondary)
                if let err = g.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(scheduleLabel(g.runAt)).font(.caption).foregroundStyle(Theme.accent)
                Image(systemName: g.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(g.status.tint)
            }
        }
    }

    private func load() async {
        groups = (try? await APIClient.shared.groups().items) ?? []
        loading = false
    }
}
