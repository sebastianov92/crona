import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Conversación estilo chat: burbujas (enviados, programados pendientes y recibidos)
/// + barra para programar un mensaje nuevo — al enviar pregunta fecha y hora.
struct ChatDetailView: View {
    @Environment(SessionStore.self) private var session

    let chat: ChatSummary

    @State private var bubbles: [ChatBubble] = []
    @State private var loading = true
    @State private var text = ""
    @State private var attachment: Attachment?
    @State private var askWhen = false
    @State private var when = Date().addingTimeInterval(3600)
    @State private var sending = false
    @State private var showRecorder = false
    @State private var showFileImporter = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif

    private var isAudio: Bool { attachment?.messageType == .AUDIO }
    private var canSend: Bool {
        !sending && (attachment != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if bubbles.isEmpty && !loading {
                            ContentUnavailableView("Sin mensajes que mostrar.", systemImage: "bubble")
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(bubbles) { b in
                            BubbleView(bubble: b)
                                .id(b.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: bubbles) { _, list in
                    if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            inputBar
        }
        .navigationTitle(chat.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .catchappChatIncoming)) { note in
            if note.userInfo?["jid"] as? String == chat.jid { Task { await load() } }
        }
        .sheet(isPresented: $showRecorder) { VoiceRecorderSheet { attachment = $0 } }
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
        .sheet(isPresented: $askWhen) { whenSheet }
    }

    // MARK: - Barra de entrada

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let attachment {
                HStack {
                    Image(systemName: isAudio ? "waveform" : "paperclip")
                        .foregroundStyle(Theme.accent)
                    Text(attachment.fileName).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Quitar") { self.attachment = nil }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                #if os(iOS)
                Menu {
                    Button { showPhotoPicker = true } label: { Label("Foto o video", systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label("Audio o archivo", systemImage: "waveform") }
                } label: {
                    Image(systemName: "paperclip").font(.title3)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #else
                Button { showFileImporter = true } label: {
                    Image(systemName: "paperclip").font(.title3)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Adjuntar foto, video, PDF o audio")
                #endif

                Button { showRecorder = true } label: {
                    Image(systemName: "mic.fill").font(.title3)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Grabar nota de voz")

                if isAudio {
                    Text("La nota de voz se envía sin texto.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                } else {
                    TextField("Escribe un mensaje", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                }

                Button {
                    when = Date().addingTimeInterval(3600)
                    askWhen = true
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(10)
    }

    private var whenSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("¿Cuándo se envía?").font(.title3.bold())
                DatePicker("Fecha y hora", selection: $when, in: Date().addingTimeInterval(120)...)
                    .datePickerStyle(.graphical)
                Button {
                    Task { await send() }
                } label: {
                    Group {
                        if sending { ProgressView().controlSize(.small) }
                        else { Text("Programar").font(.headline) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { askWhen = false } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .presentationDetents([.large])
    }

    // MARK: - Lógica

    private func load() async {
        do {
            bubbles = try await APIClient.shared.chatMessages(instanceId: chat.instanceId, jid: chat.jid).items
        } catch { session.report(error) }
        loading = false
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            var mediaId: String?
            if let attachment {
                mediaId = try await APIClient.shared.uploadMedia(
                    data: attachment.data, fileName: attachment.fileName, mimeType: attachment.mimeType
                ).mediaId
            }
            let body = CreateMessageBody(
                instanceId: chat.instanceId,
                recipient: RecipientInput(jid: chat.jid, name: chat.name, kind: chat.kind, pictureUrl: chat.pictureUrl),
                type: attachment?.messageType ?? .TEXT,
                body: isAudio ? nil : (text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text),
                mediaId: mediaId,
                scheduledAt: when,
                timezone: TimeZone.current.identifier,
                recurrence: .NONE,
                recurrenceDays: [],
                recurrenceUntil: nil
            )
            let created = try await APIClient.shared.createMessage(body)
            if !session.upcoming.contains(where: { $0.id == created.id }) {
                session.upcoming.append(created)
                session.upcoming.sort { $0.nextRunAt < $1.nextRunAt }
            }
            text = ""
            attachment = nil
            askWhen = false
            await load()
        } catch { session.report(error) }
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
        } catch { session.report(error) }
    }
    #endif

    private func loadFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? Data(contentsOf: url) {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachment = Attachment(data: data, fileName: url.lastPathComponent, mimeType: mime)
        }
    }
}

// MARK: - Burbuja

private struct BubbleView: View {
    let bubble: ChatBubble

    private var incoming: Bool { bubble.direction == .incoming }

    var body: some View {
        HStack {
            if !incoming { Spacer(minLength: 60) }
            VStack(alignment: incoming ? .leading : .trailing, spacing: 3) {
                if bubble.type != .TEXT {
                    Label(mediaLabel, systemImage: mediaIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let body = bubble.body, !body.isEmpty {
                    Text(body)
                }
                HStack(spacing: 4) {
                    if bubble.direction == .scheduled {
                        Image(systemName: "clock")
                        Text("Programado · \(bubble.at, format: .dateTime.day().month(.abbreviated).hour().minute())")
                    } else {
                        Text(bubble.at, format: .dateTime.day().month(.abbreviated).hour().minute())
                        if bubble.direction == .out, bubble.status == "DELIVERED" || bubble.status == "READ" {
                            Image(systemName: "checkmark")
                        }
                        if bubble.status == "FAILED" {
                            Image(systemName: "xmark").foregroundStyle(.red)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(bubble.direction == .scheduled ? Theme.accent : .secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if bubble.direction == .scheduled {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                }
            }
            if incoming { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        switch bubble.direction {
        case .incoming: return Color.gray.opacity(0.15)
        case .out: return Theme.accent.opacity(0.22)
        case .scheduled: return .clear
        }
    }

    private var mediaLabel: String {
        switch bubble.type {
        case .IMAGE: return "Foto"
        case .VIDEO: return "Video"
        case .DOCUMENT: return "Documento"
        case .AUDIO: return "Nota de voz"
        case .TEXT: return ""
        }
    }

    private var mediaIcon: String {
        switch bubble.type {
        case .IMAGE: return "photo"
        case .VIDEO: return "video.fill"
        case .DOCUMENT: return "doc.fill"
        case .AUDIO: return "waveform"
        case .TEXT: return "bubble"
        }
    }
}
