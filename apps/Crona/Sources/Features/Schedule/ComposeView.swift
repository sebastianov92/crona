import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Attachment: Equatable {
    let data: Data
    let fileName: String
    let mimeType: String

    var messageType: MessageType {
        if mimeType.hasPrefix("image/") { return .IMAGE }
        if mimeType.hasPrefix("video/") { return .VIDEO }
        if mimeType.hasPrefix("audio/") { return .AUDIO }
        return .DOCUMENT
    }
}

struct ComposeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    // para duplicar/editar prellenado
    var prefill: ScheduledMessage? = nil

    @State private var instanceId: String?
    @State private var recipients: [Recipient] = []
    @State private var text = ""
    @State private var attachment: Attachment?
    @State private var schedule = ScheduleConfig()

    @State private var showPicker = false
    @State private var showSchedule = false
    @State private var showConfirm = false
    @State private var sending = false
    @State private var uploading = false
    @State private var error: String?

    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif
    @State private var showFileImporter = false
    @State private var showRecorder = false
    @State private var typingStart: Date? // primer caracter escrito — alimenta la señal "escribiendo…"
    @State private var voiceMs: Int? // duración de la nota de voz grabada

    private var canSubmit: Bool {
        !recipients.isEmpty && instanceId != nil && !sending &&
        (attachment != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if session.instances.count > 1 {
                    Section("Instancia") {
                        Picker("Enviar desde", selection: $instanceId) {
                            ForEach(session.instances) { inst in
                                Text(inst.name).tag(Optional(inst.id))
                            }
                        }
                    }
                }

                Section("Destinatarios") {
                    ForEach(recipients, id: \.jid) { r in
                        HStack(spacing: 12) {
                            AvatarView(name: r.shownName, pictureUrl: r.pictureUrl, size: 36)
                            Text(r.shownName)
                            Spacer()
                            Button {
                                recipients.removeAll { $0.jid == r.jid }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        showPicker = true
                    } label: {
                        HStack {
                            Label(recipients.isEmpty ? "Elegir contactos o grupos" : "Agregar más",
                                  systemImage: "person.crop.circle.badge.plus")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())   // toda la fila clickeable, no solo texto/icono
                    }
                    .buttonStyle(.plain)
                }

                Section("Mensaje") {
                    // burbuja de preview estilo chat
                    if !text.isEmpty || attachment != nil {
                        HStack {
                            Spacer(minLength: 40)
                            VStack(alignment: .trailing, spacing: 6) {
                                if let attachment {
                                    AttachmentThumb(attachment: attachment) { self.attachment = nil }
                                }
                                if !text.isEmpty {
                                    Text(text)
                                        .padding(10)
                                        .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        #if os(iOS)
                        Menu {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Foto o video", systemImage: "photo")
                            }
                            Button {
                                showFileImporter = true
                            } label: {
                                Label("Audio o archivo", systemImage: "waveform")
                            }
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #else
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Adjuntar foto, video, PDF o nota de voz")
                        #endif

                        Button {
                            showRecorder = true
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Grabar nota de voz")

                        if attachment?.messageType == .AUDIO {
                            Text("La nota de voz se envía sin texto.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        } else {
                            TextField("Escribe un mensaje", text: $text, axis: .vertical)
                                .lineLimit(1...6)
                                .textFieldStyle(.plain)
                                .padding(8)
                                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    if attachment?.messageType != .AUDIO {
                        Text("Variables: {nombre} · {primer_nombre} · {fecha} · {dia} — se reemplazan al enviar (ej. \"Dani Vega\" → {primer_nombre} = Dani).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Envío") {
                    Button {
                        showSchedule = true
                    } label: {
                        HStack {
                            Label(scheduleLabel(schedule.date), systemImage: "calendar")
                            Spacer()
                            if schedule.recurrence != .NONE {
                                HStack(spacing: 4) {
                                    Image(systemName: recurrenceIcon)
                                    Text(recurrenceLabel)
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if uploading {
                    Section { ProgressView("Subiendo archivo…") }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Nuevo mensaje")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        // iOS: programar directo; macOS: confirmar primero (clicks accidentales de mouse)
                        #if os(iOS)
                        Task { await submit() }
                        #else
                        showConfirm = true
                        #endif
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Text("Programar") }
                    }
                    .disabled(!canSubmit)
                }
            }
            .confirmationDialog(confirmText, isPresented: $showConfirm, titleVisibility: .visible) {
                Button("Programar") { Task { await submit() } }
                Button("Cancelar", role: .cancel) {}
            }
            .sheet(isPresented: $showPicker) {
                // instanceId puede estar nil si las instancias aún no cargaron al abrir la app
                if let iid = instanceId ?? session.activeInstance?.id {
                    RecipientPickerView(instanceId: iid, multiSelect: true) { picked in
                        for r in picked where !recipients.contains(where: { $0.jid == r.jid }) {
                            recipients.append(r)
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
            .sheet(isPresented: $showSchedule) { ScheduleSheet(config: $schedule) }
            .sheet(isPresented: $showRecorder) {
                VoiceRecorderSheet { att, durationMs in
                    attachment = att
                    voiceMs = durationMs
                }
            }
            .onChange(of: text) { _, t in
                if typingStart == nil && !t.isEmpty { typingStart = .now }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            #endif
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.jpeg, .png, .webP, .mpeg4Movie, .quickTimeMovie, .pdf, .audio]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            .onAppear { applyPrefill() }
            .onChange(of: session.instances) { _, _ in
                if instanceId == nil { instanceId = session.activeInstance?.id }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var recurrenceLabel: String {
        switch schedule.recurrence {
        case .NONE: return ""
        case .DAILY: return "Todos los días"
        case .WEEKLY: return "Semanal"
        case .MONTHLY: return "Mensual"
        case .YEARLY: return "Cada año"
        }
    }

    private var confirmText: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "d 'de' MMMM"
        let hf = DateFormatter()
        hf.locale = Locale(identifier: "es")
        hf.dateFormat = "h:mm a"
        let who = recipients.count == 1
            ? (recipients.first?.displayName ?? "")
            : "\(recipients.count) destinatarios"
        return "Se enviará a \(who) el \(df.string(from: schedule.date)) a las \(hf.string(from: schedule.date))."
    }

    private func applyPrefill() {
        instanceId = instanceId ?? session.activeInstance?.id
        guard let p = prefill else { return }
        instanceId = p.instanceId
        recipients = [Recipient(id: p.recipientJid, jid: p.recipientJid, displayName: p.recipientName,
                                alias: nil, pictureUrl: p.recipientPictureUrl, kind: p.recipientKind, phoneNumber: nil)]
        text = p.body ?? ""
        schedule.date = max(p.scheduledAt, Date().addingTimeInterval(3600))
        schedule.recurrence = p.recurrence
        schedule.recurrenceDays = Set(p.recurrenceDays)
        schedule.until = p.recurrenceUntil
    }

    #if os(iOS)
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            if let movie = try await item.loadTransferable(type: MovieFile.self) {
                let data = try Data(contentsOf: movie.url)
                attachment = Attachment(data: data, fileName: movie.url.lastPathComponent, mimeType: "video/quicktime")
                try? FileManager.default.removeItem(at: movie.url)
            } else if let data = try await item.loadTransferable(type: Data.self) {
                attachment = Attachment(data: data, fileName: "foto.jpg", mimeType: "image/jpeg")
            }
            photoItem = nil
        } catch {
            self.error = "No se pudo cargar el archivo: \(error.localizedDescription)"
        }
    }
    #endif

    private func loadFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            error = "Sin permiso para leer el archivo seleccionado."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mime = mimeType(for: url)
            attachment = Attachment(data: data, fileName: url.lastPathComponent, mimeType: mime)
        } catch {
            self.error = "No se pudo leer el archivo: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Tiempo real de redacción (texto) o duración de la grabación (audio), acotado 1.5–25 s.
    private func computedTypingMs() -> Int? {
        let raw: Int?
        if attachment?.messageType == .AUDIO {
            raw = voiceMs
        } else if let typingStart {
            raw = Int(Date().timeIntervalSince(typingStart) * 1000)
        } else {
            raw = nil
        }
        return raw.map { max(1500, min(25_000, $0)) }
    }

    private func submit() async {
        guard let instanceId, !recipients.isEmpty else { return }
        error = nil; sending = true
        defer { sending = false }
        do {
            var mediaId: String?
            if let attachment {
                uploading = true
                // un solo upload, compartido por todos los mensajes
                mediaId = try await APIClient.shared.uploadMedia(
                    data: attachment.data, fileName: attachment.fileName, mimeType: attachment.mimeType
                ).mediaId
                uploading = false
            }
            let typingMs = computedTypingMs()
            // Varios destinatarios (o una lista): misma hora para todos — el worker los envía
            // UNO POR UNO (escribiendo… → envía → pausa aleatoria 3-9 s → siguiente).
            for r in recipients {
                let body = CreateMessageBody(
                    instanceId: instanceId,
                    recipient: RecipientInput(jid: r.jid, name: r.shownName,
                                              kind: r.kind, pictureUrl: r.pictureUrl),
                    type: attachment?.messageType ?? .TEXT,
                    body: attachment?.messageType == .AUDIO
                        ? nil
                        : (text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text),
                    mediaId: mediaId,
                    scheduledAt: schedule.date,
                    timezone: schedule.timezone,
                    recurrence: schedule.recurrence,
                    recurrenceDays: schedule.recurrence == .WEEKLY ? schedule.recurrenceDays.sorted() : [],
                    recurrenceUntil: schedule.until,
                    randomDelay: schedule.recurrence != .NONE && schedule.randomDelay,
                    typingMs: typingMs
                )
                let created = try await APIClient.shared.createMessage(body)
                if !session.upcoming.contains(where: { $0.id == created.id }) {
                    session.upcoming.append(created)
                }
            }
            session.upcoming.sort { $0.nextRunAt < $1.nextRunAt }
            dismiss()
        } catch {
            uploading = false
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#if os(iOS)
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}
#endif

struct AttachmentThumb: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.messageType == .IMAGE, let img = platformImage(attachment.data) {
                    img.resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: attachment.messageType == .VIDEO ? "video.fill"
                              : attachment.messageType == .AUDIO ? "waveform" : "doc.fill")
                            .font(.title2)
                        Text(attachment.fileName).font(.caption2).lineLimit(1)
                        Text(sizeLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .frame(width: 120, height: 90)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
