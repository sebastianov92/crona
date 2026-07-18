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
        return .DOCUMENT
    }
}

struct ComposeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    // para duplicar/editar prellenado
    var prefill: ScheduledMessage? = nil

    @State private var instanceId: String?
    @State private var recipient: Recipient?
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
    #endif
    @State private var showFileImporter = false

    private var canSubmit: Bool {
        recipient != nil && instanceId != nil && !sending &&
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

                Section("Destinatario") {
                    Button {
                        showPicker = true
                    } label: {
                        Group {
                            if let recipient {
                                HStack(spacing: 12) {
                                    AvatarView(name: recipient.displayName, pictureUrl: recipient.pictureUrl, size: 40)
                                    Text(recipient.displayName)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                HStack {
                                    Label("Elegir contacto o grupo", systemImage: "person.crop.circle.badge.plus")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }
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
                        PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
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
                        .help("Adjuntar foto, video o PDF")
                        #endif

                        TextField("Escribe un mensaje", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
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
                        showConfirm = true
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
                if let instanceId {
                    RecipientPickerView(instanceId: instanceId) { recipient = $0 }
                }
            }
            .sheet(isPresented: $showSchedule) { ScheduleSheet(config: $schedule) }
            #if os(iOS)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            #endif
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.jpeg, .png, .webP, .mpeg4Movie, .quickTimeMovie, .pdf]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            .onAppear { applyPrefill() }
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
        }
    }

    private var confirmText: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "d 'de' MMMM"
        let hf = DateFormatter()
        hf.locale = Locale(identifier: "es")
        hf.dateFormat = "h:mm a"
        return "Se enviará a \(recipient?.displayName ?? "") el \(df.string(from: schedule.date)) a las \(hf.string(from: schedule.date))."
    }

    private func applyPrefill() {
        instanceId = instanceId ?? session.activeInstance?.id
        guard let p = prefill else { return }
        instanceId = p.instanceId
        recipient = Recipient(id: p.recipientJid, jid: p.recipientJid, displayName: p.recipientName,
                              pictureUrl: p.recipientPictureUrl, kind: p.recipientKind, phoneNumber: nil)
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
        guard url.startAccessingSecurityScopedResource() else { return }
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

    private func submit() async {
        guard let instanceId, let recipient else { return }
        error = nil; sending = true
        defer { sending = false }
        do {
            var mediaId: String?
            if let attachment {
                uploading = true
                mediaId = try await APIClient.shared.uploadMedia(
                    data: attachment.data, fileName: attachment.fileName, mimeType: attachment.mimeType
                ).mediaId
                uploading = false
            }
            let body = CreateMessageBody(
                instanceId: instanceId,
                recipient: RecipientInput(jid: recipient.jid, name: recipient.displayName,
                                          kind: recipient.kind, pictureUrl: recipient.pictureUrl),
                type: attachment?.messageType ?? .TEXT,
                body: text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text,
                mediaId: mediaId,
                scheduledAt: schedule.date,
                timezone: TimeZone.current.identifier,
                recurrence: schedule.recurrence,
                recurrenceDays: schedule.recurrence == .WEEKLY ? schedule.recurrenceDays.sorted() : [],
                recurrenceUntil: schedule.until
            )
            let created = try await APIClient.shared.createMessage(body)
            // update optimista: el WS también lo traerá
            if !session.upcoming.contains(where: { $0.id == created.id }) {
                session.upcoming.append(created)
                session.upcoming.sort { $0.nextRunAt < $1.nextRunAt }
            }
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
                        Image(systemName: attachment.messageType == .VIDEO ? "video.fill" : "doc.fill")
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
