import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Attachment: Equatable {
    let data: Data
    let fileName: String
    let mimeType: String
    // el usuario eligió "Sticker": una imagen (webp/png/jpg) se envía como sticker, no como foto
    var asSticker: Bool = false

    var messageType: MessageType {
        if asSticker { return .STICKER }
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
    // Lista homogénea de partes: cada una de cualquier tipo, en el orden que el usuario quiera.
    @State private var parts: [ComposePart] = [ComposePart(kind: .text)]
    @State private var focusRequest: UUID? // pide enfocar una parte concreta (al agregar texto)
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
    @State private var showStickerImporter = false
    @State private var showStickerPicker = false
    @State private var showRecorder = false
    @State private var showTemplates = false

    /// Total de partes (la parte 0 va en los campos raíz; el resto en "parts", máx. 9 adicionales).
    private let maxParts = 10

    private var canSubmit: Bool {
        !recipients.isEmpty && instanceId != nil && !sending && parts.contains { $0.isSendable }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                    // Lista unificada de partes: texto, foto/video, nota de voz o sticker, en orden.
                    ComposePartsEditor(parts: $parts, focusRequest: $focusRequest, scrollProxy: proxy)

                    // "+" al final: elige el tipo de la nueva parte.
                    addPartMenu

                    Button {
                        showTemplates = true
                    } label: {
                        Label("Usar plantilla", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if parts.contains(where: { $0.hasTextField }) {
                        Text("Variables: {nombre} · {primer_nombre} · {fecha} · {dia} — se reemplazan al enviar (ej. \"Dani Vega\" → {primer_nombre} = Dani).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if sendableCount > 1 {
                        Text("Se enviarán \(sendableCount) mensajes seguidos, con una pausa corta entre cada uno.")
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
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
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
                // Nota de voz: agrega una parte de audio con su duración.
                VoiceRecorderSheet { att, durationMs in
                    addPart(ComposePart(kind: .audio, attachment: att, durationMs: durationMs))
                }
            }
            .sheet(isPresented: $showTemplates) {
                TemplatePickerSheet(kind: .MESSAGE) { tplParts in applyTemplate(tplParts) }
            }
            .sheet(isPresented: $showStickerPicker) {
                // Sticker de la biblioteca: agrega una parte de sticker.
                StickerPickerView { att in addPart(ComposePart(kind: .sticker, attachment: att)) }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            #endif
            // Foto/video (macOS): solo imágenes y videos; el audio va por la grabadora.
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.jpeg, .png, .webP, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            // Sticker: solo imágenes; se marca asSticker para enviarlo como sticker y no como foto
            .fileImporter(isPresented: $showStickerImporter,
                          allowedContentTypes: [.webP, .png, .jpeg]) { result in
                if case .success(let url) = result { loadFile(url, asSticker: true) }
            }
            .onAppear { applyPrefill() }
            .onChange(of: session.instances) { _, _ in
                if instanceId == nil { instanceId = session.activeInstance?.id }
            }
            } // ScrollViewReader
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    /// Menú "+" para agregar una parte de cualquier tipo, al final de la lista.
    @ViewBuilder private var addPartMenu: some View {
        Menu {
            Button {
                addTextPart()
            } label: {
                Label("Texto", systemImage: "text.bubble")
            }
            Button {
                #if os(iOS)
                showPhotoPicker = true
                #else
                showFileImporter = true
                #endif
            } label: {
                Label("Foto o video", systemImage: "photo")
            }
            Button {
                showRecorder = true
            } label: {
                Label("Nota de voz", systemImage: "mic.fill")
            }
            Button {
                showStickerPicker = true
            } label: {
                Label("Mis stickers", systemImage: "square.grid.2x2")
            }
            Button {
                showStickerImporter = true
            } label: {
                Label("Sticker desde archivo", systemImage: "face.smiling")
            }
        } label: {
            Label("Agregar parte", systemImage: "plus.circle")
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(parts.count >= maxParts)
    }

    /// Cuántas partes se enviarán realmente (las que tienen contenido).
    private var sendableCount: Int { parts.filter { $0.isSendable }.count }

    /// Agrega una parte de texto y le pide el foco. Si solo hay una parte de texto vacía, la reutiliza.
    private func addTextPart() {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty {
            focusRequest = parts[0].id
        } else {
            let p = ComposePart(kind: .text)
            parts.append(p)
            focusRequest = p.id
        }
    }

    /// Agrega una parte de media. Si la única parte es un texto vacío sin usar, la sustituye
    /// para no dejar un campo de texto vacío colgando arriba.
    private func addPart(_ part: ComposePart) {
        if parts.count == 1, parts[0].kind == .text, parts[0].trimmed.isEmpty, parts[0].attachment == nil {
            parts[0] = part
        } else {
            parts.append(part)
        }
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
        // Se reconstruyen solo las partes de texto; los adjuntos se re-adjuntan a mano al duplicar.
        var rebuilt: [ComposePart] = []
        if p.type == .TEXT, let b = p.body, !b.isEmpty {
            rebuilt.append(ComposePart(kind: .text, text: b))
        }
        for part in (p.parts ?? []) where part.type == .TEXT {
            rebuilt.append(ComposePart(kind: .text, text: part.body ?? "", presetTypingMs: part.typingMs))
        }
        parts = rebuilt.isEmpty ? [ComposePart(kind: .text)] : rebuilt
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
                addPart(ComposePart(kind: .photoVideo,
                                    attachment: Attachment(data: data, fileName: movie.url.lastPathComponent,
                                                           mimeType: "video/quicktime")))
                try? FileManager.default.removeItem(at: movie.url)
            } else if let data = try await item.loadTransferable(type: Data.self) {
                addPart(ComposePart(kind: .photoVideo,
                                    attachment: Attachment(data: data, fileName: "foto.jpg", mimeType: "image/jpeg")))
            }
            photoItem = nil
        } catch {
            self.error = "No se pudo cargar el archivo: \(error.localizedDescription)"
        }
    }
    #endif

    private func loadFile(_ url: URL, asSticker: Bool = false) {
        guard url.startAccessingSecurityScopedResource() else {
            error = "Sin permiso para leer el archivo seleccionado."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mime = mimeType(for: url)
            let att = Attachment(data: data, fileName: url.lastPathComponent, mimeType: mime, asSticker: asSticker)
            addPart(ComposePart(kind: asSticker ? .sticker : .photoVideo, attachment: att))
        } catch {
            self.error = "No se pudo leer el archivo: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Copia las partes de la plantilla como partes de texto; la plantilla en sí no se toca.
    private func applyTemplate(_ tplParts: [TemplatePart]) {
        let mapped = tplParts.map { ComposePart(kind: .text, text: $0.body, presetTypingMs: $0.typingMs) }
        parts = mapped.isEmpty ? [ComposePart(kind: .text)] : mapped
    }

    private func submit() async {
        guard let instanceId, !recipients.isEmpty else { return }
        let sendParts = parts.filter { $0.isSendable }
        guard let firstPart = sendParts.first else { return }
        error = nil; sending = true
        defer { sending = false }
        do {
            // Sube el media de CADA parte que lo tenga; guarda el mediaId por id de parte.
            var mediaIds: [UUID: String] = [:]
            let partsWithMedia = sendParts.filter { $0.attachment != nil }
            if !partsWithMedia.isEmpty {
                uploading = true
                for part in partsWithMedia {
                    guard let att = part.attachment else { continue }
                    mediaIds[part.id] = try await APIClient.shared.uploadMedia(
                        data: att.data, fileName: att.fileName, mimeType: att.mimeType
                    ).mediaId
                }
                uploading = false
            }
            // Partes adicionales (la parte 0 va en los campos raíz): cada una con su tipo, adjunto y typingMs.
            let extraParts = sendParts.dropFirst().map { part in
                MessagePart(type: part.messageType, body: part.bodyText,
                            mediaId: mediaIds[part.id], typingMs: part.typingMs)
            }
            // Varios destinatarios (o una lista): misma hora para todos — el worker los envía
            // UNO POR UNO (escribiendo… → envía → pausa aleatoria 3-9 s → siguiente).
            for r in recipients {
                let body = CreateMessageBody(
                    instanceId: instanceId,
                    recipient: RecipientInput(jid: r.jid, name: r.shownName,
                                              kind: r.kind, pictureUrl: r.pictureUrl),
                    type: firstPart.messageType,
                    body: firstPart.bodyText,
                    mediaId: mediaIds[firstPart.id],
                    scheduledAt: schedule.date,
                    timezone: schedule.timezone,
                    recurrence: schedule.recurrence,
                    recurrenceDays: schedule.recurrence == .WEEKLY ? schedule.recurrenceDays.sorted() : [],
                    recurrenceUntil: schedule.until,
                    randomDelay: schedule.recurrence != .NONE && schedule.randomDelay,
                    typingMs: firstPart.typingMs,
                    parts: Array(extraParts)
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

