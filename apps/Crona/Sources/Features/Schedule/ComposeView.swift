import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Endereza una foto: hornea la orientación EXIF en los píxeles y re-codifica. WhatsApp no
/// respeta la orientación EXIF, así que una foto vertical llegaría rotada si no se corrige.
func uprightImageData(_ data: Data, mime: String) -> Data {
    #if canImport(UIKit)
    guard mime.hasPrefix("image/"), !mime.contains("webp"),
          let img = UIImage(data: data), img.imageOrientation != .up else { return data }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = img.scale
    let upright = UIGraphicsImageRenderer(size: img.size, format: format).image { _ in
        img.draw(in: CGRect(origin: .zero, size: img.size))
    }
    return upright.jpegData(compressionQuality: 0.95) ?? data
    #else
    return data
    #endif
}

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

    // para duplicar (prellena solo texto)
    var prefill: ScheduledMessage? = nil
    // para editar: reconstruye TODO (partes + media); al guardar crea el editado y borra el viejo
    var editing: ScheduledMessage? = nil
    // avisa al presentador que se guardó (p.ej. cerrar el detalle del mensaje original ya borrado)
    var onSaved: (() -> Void)? = nil
    // preseleccionar destinatario(s) e instancia (p.ej. "programar mensaje a este grupo")
    var initialRecipients: [Recipient]? = nil
    var initialInstanceId: String? = nil

    @State private var didLoadEdit = false
    @State private var didRestoreDraft = false
    @State private var draftRestored = false     // muestra el aviso "borrador recuperado"
    @State private var instanceId: String?
    @State private var recipients: [Recipient] = []
    // Lista homogénea de partes: cada una de cualquier tipo, en el orden que el usuario quiera.
    @State private var parts: [ComposePart] = [ComposePart(kind: .text)]
    @State private var focusRequest: UUID? // pide enfocar una parte concreta (al agregar texto)
    #if os(iOS)
    @State private var editMode: EditMode = .inactive // modo "Reordenar" partes (asas de arrastre)
    #endif
    @State private var schedule = ScheduleConfig()

    @State private var showPicker = false
    @State private var didAutoOpenPicker = false
    @State private var showSchedule = false
    @State private var showConfirm = false
    @State private var sending = false
    @State private var uploading = false
    @State private var error: String?

    #if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []   // multi-selección de fotos/videos
    @State private var showPhotoPicker = false
    #endif
    @State private var showFileImporter = false
    private enum ImportKind { case media, document }         // el fileImporter sirve para foto (macOS) o documento
    @State private var importKind: ImportKind = .media
    @State private var showStickerPicker = false
    @State private var showRecorder = false
    @State private var showTemplates = false
    // plantilla pendiente de aplicar cuando ya hay contenido: pregunta añadir o reemplazar
    @State private var pendingTemplate: [TemplatePart]?

    /// Total de partes (la parte 0 va en los campos raíz; el resto en "parts", máx. 9 adicionales).
    private let maxParts = 10

    private var canSubmit: Bool {
        !recipients.isEmpty && instanceId != nil && !sending && parts.contains { $0.isSendable }
            && (schedule.recurrence != .WEEKLY || !schedule.recurrenceDays.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if draftRestored { draftBanner }
                if session.instances.count > 1 {
                    Section("Instancia") {
                        Picker("Enviar desde", selection: $instanceId) {
                            ForEach(session.instances) { inst in
                                Text(inst.name).tag(Optional(inst.id))
                            }
                        }
                    }
                }

                recipientsSection

                messageSection(proxy)

                scheduleSection

                if uploading {
                    Section { ProgressView("Subiendo archivo…") }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .environment(\.editMode, $editMode)   // "Reordenar" activa las asas de arrastre de las partes
            .scrollDismissesKeyboard(.interactively)
            #endif
            // Barra de acciones fija sobre el teclado: siempre visible al escribir, sin depender
            // del scroll (antes al agregar una nota de voz quedaba tapada a medias).
            .safeAreaInset(edge: .bottom) {
                addPartBar
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
            .navigationTitle(editing == nil ? "Nuevo mensaje" : "Editar mensaje")
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
                        if sending { ProgressView().controlSize(.small) }
                        else { Text(editing == nil ? "Programar" : "Guardar") }
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
                    // Sin destinatarios → single (tocar elige y cierra); "Agregar más" → multi
                    // con casillas y los ya elegidos pre-marcados. Devuelve el set completo.
                    RecipientPickerView(instanceId: iid,
                                        startInMulti: !recipients.isEmpty,
                                        preselected: recipients) { picked in
                        recipients = picked
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
            .confirmationDialog(
                "Ya escribiste contenido",
                isPresented: Binding(get: { pendingTemplate != nil },
                                     set: { if !$0 { pendingTemplate = nil } }),
                titleVisibility: .visible
            ) {
                Button("Añadir al final") {
                    if let t = pendingTemplate { appendTemplate(t) }
                    pendingTemplate = nil
                }
                Button("Reemplazar", role: .destructive) {
                    if let t = pendingTemplate { parts = mappedTemplate(t) }
                    pendingTemplate = nil
                }
                Button("Cancelar", role: .cancel) { pendingTemplate = nil }
            } message: {
                Text("La plantilla puede añadirse a lo que ya tienes o reemplazarlo.")
            }
            .sheet(isPresented: $showStickerPicker) {
                // Sticker de la biblioteca: agrega una parte de sticker.
                StickerPickerView { att in addPart(ComposePart(kind: .sticker, attachment: att)) }
            }
            #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                          maxSelectionCount: max(1, maxParts - parts.count), matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            #endif
            // fileImporter compartido: foto/video (macOS) o documento (PDF/otros) según importKind.
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: importKind == .document
                            ? [.pdf, .plainText, .commaSeparatedText, .zip, .data]
                            : [.jpeg, .png, .webP, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: importKind != .document) { result in
                if case .success(let urls) = result { for url in urls { loadFile(url) } }
            }
            .onAppear {
                applyPrefill()
                if let editing {
                    if !didLoadEdit { didLoadEdit = true; Task { await loadEditing(editing) } }
                    return // editando: destinatario y partes vienen del mensaje, no se abre el picker
                }
                // Destinatario preseleccionado (p.ej. desde la gestión de un grupo): no abrir el picker.
                if recipients.isEmpty, let initial = initialRecipients, !initial.isEmpty {
                    recipients = initial
                    if let iid = initialInstanceId { instanceId = iid }
                }
                // Borrador recuperado (solo en un compose nuevo): restaura destinatarios/texto/fecha.
                if isFreshCompose, !didRestoreDraft {
                    didRestoreDraft = true
                    if let d = DraftStore.load() {
                        recipients = d.recipients
                        if let iid = d.instanceId { instanceId = iid }
                        let textParts = d.texts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            .map { ComposePart(kind: .text, text: $0) }
                        if !textParts.isEmpty { parts = textParts }
                        schedule.date = d.date
                        draftRestored = true
                    }
                }
                // Mensaje nuevo (no edición/duplicado): abrir el selector de contacto de una vez.
                if prefill == nil, recipients.isEmpty, !didAutoOpenPicker {
                    didAutoOpenPicker = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(350)) // deja asentar la hoja antes de abrir otra
                        if recipients.isEmpty { showPicker = true }
                    }
                }
            }
            .onChange(of: session.instances) { _, _ in
                if instanceId == nil { instanceId = session.activeInstance?.id }
            }
            // Al agregar una parte (foto/voz/sticker/texto) baja a la última para verla.
            .onChange(of: parts.count) { _, _ in
                guard let last = parts.last?.id else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100)) // deja que la fila nueva se dibuje
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            // Autoguardado del borrador (solo en un compose nuevo): un solo onChange sobre una
            // firma combinada (destinatarios + textos + fecha) para no alargar la cadena.
            .onChange(of: draftKey) { _, _ in saveDraft() }
            } // ScrollViewReader
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    /// Compose "en blanco" (no edición, ni duplicado, ni destinatario preseleccionado): el único
    /// caso en que tiene sentido autoguardar/recuperar un borrador.
    private var isFreshCompose: Bool { editing == nil && prefill == nil && (initialRecipients?.isEmpty ?? true) }

    /// Firma del borrador: cambia cuando cambian destinatarios, textos o fecha.
    private var draftKey: String {
        recipients.map(\.jid).joined(separator: ",") + "|"
        + parts.filter { $0.kind == .text }.map(\.text).joined(separator: "\u{1}") + "|"
        + String(schedule.date.timeIntervalSince1970)
    }

    private func saveDraft() {
        guard isFreshCompose else { return }
        let texts = parts.filter { $0.kind == .text }.map(\.text)
        DraftStore.save(ComposeDraft(instanceId: instanceId, recipients: recipients,
                                     texts: texts, date: schedule.date, savedAt: Date()))
    }

    @ViewBuilder private var recipientsSection: some View {
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

            // Aviso (no bloquea): difundir a muchos de golpe es lo que más arriesga el número.
            if recipients.count >= 5 {
                Label("Vas a programar \(recipients.count) envíos. Saldrán escalonados para cuidar tu número.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func messageSection(_ proxy: ScrollViewProxy) -> some View {
        Section {
            // Lista unificada de partes: texto, foto/video, nota de voz o sticker, en orden.
            ComposePartsEditor(parts: $parts, focusRequest: $focusRequest, scrollProxy: proxy)

            Button {
                showTemplates = true
            } label: {
                Label("Usar plantilla", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if parts.contains(where: { $0.hasTextField }) {
                VariableChips { insertVariable($0) }
                Text("Toca una variable para insertarla; se reemplaza al enviar (ej. {primer_nombre} → Dani).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if sendableCount > 1 {
                Text("Se enviarán \(sendableCount) mensajes seguidos, con una pausa corta entre cada uno.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Mensaje")
                Spacer()
                #if os(iOS)
                if parts.count > 1 {
                    Button(editMode == .active ? "Listo" : "Reordenar") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                    .foregroundStyle(Theme.accent)
                }
                #endif
            }
        }
    }

    @ViewBuilder private var scheduleSection: some View {
        Section("Envío") {
            // Franja rápida inline: 1 tap fija la hora, sin abrir la hoja.
            QuickHourChips(date: $schedule.date)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            // Fecha/hora exacta, recurrencia y zona horaria → hoja completa.
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
                    Text("Otra fecha").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var draftBanner: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Theme.accent)
                Text("Recuperamos tu borrador.").font(.subheadline)
                Spacer()
                Button("Descartar") {
                    DraftStore.clear()
                    recipients = []
                    parts = [ComposePart(kind: .text)]
                    draftRestored = false
                }
                .font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Barra inline para agregar una parte de cualquier tipo — 1 tap por tipo, estilo WhatsApp.
    /// El sticker abre "Mis stickers" (que trae dentro el "+" para subir desde archivo).
    @ViewBuilder private var addPartBar: some View {
        HStack(spacing: 6) {
            partButton("Texto", "text.bubble") { addTextPart() }
            partButton("Foto", "photo") {
                #if os(iOS)
                showPhotoPicker = true
                #else
                importKind = .media; showFileImporter = true
                #endif
            }
            partButton("Voz", "mic.fill") { showRecorder = true }
            partButton("Sticker", "face.smiling") { showStickerPicker = true }
            Menu {
                Button { importKind = .document; showFileImporter = true } label: { Label("Documento", systemImage: "doc") }
                Button { addPart(ComposePart(kind: .poll)) } label: { Label("Encuesta", systemImage: "chart.bar.doc.horizontal") }
                Button { addPart(ComposePart(kind: .location)) } label: { Label("Ubicación", systemImage: "mappin.and.ellipse") }
                Button { addPart(ComposePart(kind: .contact)) } label: { Label("Contacto", systemImage: "person.crop.rectangle") }
            } label: {
                partButtonLabel("Más", "ellipsis")
            }
            .buttonStyle(.plain)
        }
        .disabled(parts.count >= maxParts)
    }

    private func partButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { partButtonLabel(label, icon) }
            .buttonStyle(.plain)
    }

    private func partButtonLabel(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label).font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(Theme.accent)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Cuántas partes se enviarán realmente (las que tienen contenido).
    private var sendableCount: Int { parts.filter { $0.isSendable }.count }

    /// Inserta una variable al final de la primera parte de texto (o crea una).
    private func insertVariable(_ v: String) {
        if let i = parts.firstIndex(where: { $0.kind == .text }) {
            if !parts[i].text.isEmpty && !parts[i].text.hasSuffix(" ") { parts[i].text += " " }
            parts[i].text += v
        } else {
            parts.insert(ComposePart(kind: .text, text: v), at: 0)
        }
    }

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
    /// Carga varias fotos/videos elegidos a la vez, en orden, como partes.
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items { await loadPhoto(item) }
        photoItems = []
    }

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
                                    attachment: Attachment(data: uprightImageData(data, mime: "image/jpeg"),
                                                           fileName: "foto.jpg", mimeType: "image/jpeg")))
            }
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
            let bytes = asSticker ? data : uprightImageData(data, mime: mime) // endereza fotos, no stickers
            let att = Attachment(data: bytes, fileName: url.lastPathComponent, mimeType: mime, asSticker: asSticker)
            addPart(ComposePart(kind: asSticker ? .sticker : .photoVideo, attachment: att))
        } catch {
            self.error = "No se pudo leer el archivo: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Copia las partes de la plantilla como partes de texto; la plantilla en sí no se toca.
    /// Si el borrador ya tiene contenido, pregunta añadir o reemplazar (no lo destruye en silencio).
    private func applyTemplate(_ tplParts: [TemplatePart]) {
        let mapped = mappedTemplate(tplParts)
        guard !mapped.isEmpty else { return }
        if parts.contains(where: { $0.isSendable }) {
            pendingTemplate = tplParts   // dispara el diálogo añadir/reemplazar
        } else {
            parts = mapped
        }
    }

    private func mappedTemplate(_ tplParts: [TemplatePart]) -> [ComposePart] {
        tplParts.map { p in
            var cp = composePart(type: p.type, body: p.body, mediaId: p.mediaId, extra: nil)
            cp.presetTypingMs = p.typingMs
            return cp
        }
    }

    /// Añade las partes de la plantilla al final, respetando el máximo de partes.
    private func appendTemplate(_ tplParts: [TemplatePart]) {
        let room = maxParts - parts.count
        guard room > 0 else { return }
        parts.append(contentsOf: mappedTemplate(tplParts).prefix(room))
    }

    /// Reconstruye el compositor desde un mensaje existente para editarlo (partes + media + fecha).
    private func loadEditing(_ msg: ScheduledMessage) async {
        instanceId = msg.instanceId
        recipients = [Recipient(id: msg.recipientJid, jid: msg.recipientJid, displayName: msg.recipientName,
                                alias: nil, pictureUrl: msg.recipientPictureUrl, kind: msg.recipientKind, phoneNumber: nil)]
        schedule.date = max(msg.nextRunAt, Date().addingTimeInterval(120))
        schedule.timezone = msg.timezone
        schedule.recurrence = msg.recurrence
        schedule.recurrenceDays = Set(msg.recurrenceDays)
        schedule.until = msg.recurrenceUntil
        schedule.randomDelay = msg.randomDelay
        // El detalle trae todas las partes con su media; la parte 0 va en los campos raíz.
        if let detail = try? await APIClient.shared.messageDetail(id: msg.id) {
            let m = detail.message
            var rebuilt: [ComposePart] = [composePart(type: m.type, body: m.body, mediaId: m.mediaId, extra: m.extra)]
            for p in (m.parts ?? []) {
                rebuilt.append(composePart(type: p.type, body: p.body, mediaId: p.mediaId, extra: p.extra))
            }
            parts = rebuilt
        }
    }

    /// Crea una ComposePart a partir de una parte existente del servidor (referencia su media por id).
    private func composePart(type: MessageType, body: String?, mediaId: String?, extra: MessageExtra?) -> ComposePart {
        switch type {
        case .TEXT:
            return ComposePart(kind: .text, text: body ?? "")
        case .IMAGE, .VIDEO, .DOCUMENT:
            var p = ComposePart(kind: .photoVideo, text: body ?? "")
            p.existingMediaId = mediaId; p.existingType = type
            if type == .DOCUMENT { p.asFile = true }
            return p
        case .AUDIO:
            var p = ComposePart(kind: .audio); p.existingMediaId = mediaId; p.existingType = type; return p
        case .STICKER:
            var p = ComposePart(kind: .sticker); p.existingMediaId = mediaId; p.existingType = type; return p
        case .POLL:
            var p = ComposePart(kind: .poll)
            p.pollQuestion = extra?.question ?? ""
            p.pollOptions = (extra?.options?.isEmpty == false) ? extra!.options! : ["", ""]
            p.pollMultiple = extra?.multiple ?? false
            return p
        case .LOCATION:
            var p = ComposePart(kind: .location)
            p.latitude = extra?.latitude; p.longitude = extra?.longitude
            p.locName = extra?.name ?? ""; p.locAddress = extra?.address ?? ""
            return p
        case .CONTACT:
            var p = ComposePart(kind: .contact)
            p.contactName = extra?.fullName ?? ""; p.contactPhone = extra?.phone ?? ""
            return p
        }
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
            // Reutilizar el media ya subido (al editar o aplicar plantilla) sin volver a subirlo.
            for part in sendParts where part.attachment == nil {
                if let mid = part.existingMediaId { mediaIds[part.id] = mid }
            }
            // Partes adicionales (la parte 0 va en los campos raíz): cada una con su tipo, adjunto y typingMs.
            let extraParts = sendParts.dropFirst().map { part in
                MessagePart(type: part.messageType, body: part.bodyText,
                            mediaId: mediaIds[part.id], extra: part.extra, typingMs: part.typingMs)
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
                    extra: firstPart.extra,
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
            // Editar = se creó el mensaje editado; ahora se retira el original (cancelar → borrar).
            if let editing {
                _ = try? await APIClient.shared.cancelMessage(id: editing.id)
                _ = try? await APIClient.shared.deleteMessage(id: editing.id)
                session.upcoming.removeAll { $0.id == editing.id }
            }
            session.upcoming.sort { $0.nextRunAt < $1.nextRunAt }
            DraftStore.clear()   // enviado → el borrador ya no aplica
            onSaved?()
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

