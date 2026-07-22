import SwiftUI
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
    @State private var parts: [PartDraft] = [PartDraft()]

    @State private var pictureMediaId: String?
    @State private var pickedPicture: Data?

    @State private var scheduled = false
    @State private var date = Date().addingTimeInterval(3600)

    @State private var showPicker = false
    @State private var showTemplates = false
    @State private var showFileImporter = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif

    @State private var busy = false
    @State private var error: String?
    @State private var created: GroupCreation?

    private var canSubmit: Bool {
        instanceId != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !participants.isEmpty && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                if created != nil {
                    resultSection
                } else {
                    formSections
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Crear grupo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancelar" : "Cerrar") { dismiss() }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submit() }
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
                    RecipientPickerView(instanceId: iid, multiSelect: true, allowGroups: false) { picked in
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
                TemplatePickerSheet(kind: .GROUP_INITIAL) { tplParts in
                    parts = tplParts.map { PartDraft(text: $0.body, presetTypingMs: $0.typingMs) }
                    if parts.isEmpty { parts = [PartDraft()] }
                }
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
            #endif
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.jpeg, .png]) { result in
                if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    pickedPicture = try? Data(contentsOf: url)
                }
            }
            .onAppear {
                instanceId = instanceId ?? session.activeInstance?.id
                pictureMediaId = session.user?.defaultGroupPictureMediaId
            }
            .onChange(of: session.instances) { _, _ in
                if instanceId == nil { instanceId = session.activeInstance?.id }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 580)
        #endif
    }

    // MARK: - Formulario

    @ViewBuilder
    private var formSections: some View {
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
                        showFileImporter = true
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
            PartsEditor(parts: $parts, minParts: 1, maxParts: 10,
                        placeholder: "Mensaje de bienvenida (opcional)")
            Button {
                showTemplates = true
            } label: {
                Label("Usar plantilla", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            let body = CreateGroupBody(
                instanceId: instanceId,
                name: name.trimmingCharacters(in: .whitespaces),
                pictureMediaId: mediaId,
                participants: participants.map { GroupParticipant(jid: $0.jid, name: $0.shownName) },
                parts: parts.filter { !$0.isEmpty }.map(\.templatePart),
                scheduledAt: scheduled ? date : nil
            )
            created = try await APIClient.shared.createGroup(body)
            if !scheduled { await pollStatus() }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Creación inmediata: el servidor tarda unos segundos, así que se refresca hasta
    /// que quede en DONE o FAILED (para poder mostrar lastError).
    private func pollStatus() async {
        guard let id = created?.id else { return }
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(3))
            guard let items = try? await APIClient.shared.groups().items,
                  let fresh = items.first(where: { $0.id == id }) else { continue }
            created = fresh
            if fresh.status == .DONE || fresh.status == .FAILED { return }
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

    private func load() async {
        groups = (try? await APIClient.shared.groups().items) ?? []
        loading = false
    }
}
