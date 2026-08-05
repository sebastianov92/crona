import SwiftUI

struct MessageDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let messageId: String

    @State private var detail: MessageDetail?
    @State private var busy = false
    @State private var showEdit = false
    @State private var confirmCancel = false
    @State private var confirmSendNow = false
    @State private var editCopy: ScheduledMessage?   // copia recién duplicada, para editarla al vuelo

    private var msg: ScheduledMessage? { detail?.message }
    private var editable: Bool {
        guard let msg else { return false }
        return (msg.status == .ACTIVE || msg.status == .PAUSED) && msg.nextRunAt > Date().addingTimeInterval(60)
    }

    var body: some View {
        Group {
            if let msg {
                List {
                    Section {
                        HStack(spacing: 12) {
                            AvatarView(name: msg.recipientName, pictureUrl: msg.recipientPictureUrl)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.recipientName).font(.headline)
                                Text(msg.recipientKind == .GROUP ? "Grupo" : "Contacto")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(msg.status.label, systemImage: msg.status.systemImage)
                                .font(.caption)
                                .foregroundStyle(msg.status.tint)
                        }
                    }

                    Section(msg.partCount > 1 ? "Mensajes (\(msg.partCount))" : "Mensaje") {
                        if let mediaId = msg.mediaId {
                            MediaPreviewView(mediaId: mediaId, type: msg.type)
                        }
                        if let body = msg.body, !body.isEmpty {
                            partRow(index: 0, total: msg.partCount, text: body)
                        }
                        // split: el resto de partes, en el orden en que se enviarán
                        ForEach(Array((msg.parts ?? []).enumerated()), id: \.offset) { i, part in
                            if let mediaId = part.mediaId {
                                MediaPreviewView(mediaId: mediaId, type: part.type)
                            }
                            if let body = part.body, !body.isEmpty {
                                partRow(index: i + 1, total: msg.partCount, text: body)
                            }
                        }
                    }

                    Section("Programación") {
                        LabeledContent("Envío", value: scheduleLabel(msg.nextRunAt))
                        if msg.timezone != TimeZone.current.identifier {
                            LabeledContent("Zona horaria", value: timezoneLabel(msg.timezone))
                        }
                        if msg.isAutoReply {
                            LabeledContent("Origen", value: "Respuesta automática")
                        }
                        if msg.recurrence != .NONE {
                            LabeledContent("Repite", value: recurrenceText(msg))
                            if msg.randomDelay {
                                LabeledContent("Variación", value: "aleatoria +1–5 min")
                            }
                            if let until = msg.recurrenceUntil {
                                LabeledContent("Hasta", value: until.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                        if let err = msg.lastError {
                            LabeledContent("Último error") { Text(err).foregroundStyle(.red) }
                        }
                    }

                    if let logs = detail?.logs, !logs.isEmpty {
                        Section("Envíos") {
                            ForEach(logs) { log in
                                HStack {
                                    Image(systemName: log.status.systemImage)
                                        .foregroundStyle(log.status.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(log.status.label)
                                        if let err = log.error {
                                            Text(err).font(.caption).foregroundStyle(.red)
                                        }
                                    }
                                    Spacer()
                                    Text(log.runAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        if msg.status == .ACTIVE || msg.status == .PAUSED {
                            Button {
                                confirmSendNow = true
                            } label: {
                                Label("Enviar ahora", systemImage: "paperplane.fill")
                            }
                        }
                        if msg.status == .FAILED {
                            Button {
                                Task { await sendNow() }
                            } label: {
                                Label("Reintentar", systemImage: "arrow.clockwise")
                            }
                        }
                        if editable {
                            Menu {
                                Button("En 1 hora") { Task { await snooze(to: Date().addingTimeInterval(3600)) } }
                                Button("Esta noche (20:00)") { Task { await snooze(to: nextAt(hour: 20)) } }
                                Button("Mañana (9:00)") { Task { await snooze(to: tomorrowAt(hour: 9)) } }
                            } label: {
                                // toda la fila abre el menú (no solo el texto)
                                Label("Posponer", systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            Button {
                                Task { await toggle() }
                            } label: {
                                Label(msg.status == .PAUSED ? "Reanudar" : "Pausar",
                                      systemImage: msg.status == .PAUSED ? "play.fill" : "pause.fill")
                            }
                            Button(role: .destructive) { confirmCancel = true } label: {
                                Label("Cancelar envío", systemImage: "xmark.circle")
                            }
                        }
                        Button {
                            Task { await duplicate() }
                        } label: {
                            Label("Duplicar", systemImage: "plus.square.on.square")
                        }
                        if [.CANCELLED, .COMPLETED, .FAILED].contains(msg.status) {
                            Button(role: .destructive) {
                                Task { await remove() }
                            } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Detalle")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            if editable {
                ToolbarItem(placement: .primaryAction) { Button("Editar") { showEdit = true } }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .cronaLogUpdated)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showEdit, onDismiss: { Task { await load() } }) {
            if let msg { EditMessageView(message: msg) }
        }
        .sheet(item: $editCopy, onDismiss: { Task { await session.refreshMessages() } }) { copy in
            EditMessageView(message: copy)
        }
        .alert("¿Cancelar este envío?", isPresented: $confirmCancel) {
            Button("Cancelar envío", role: .destructive) { Task { await cancel() } }
            Button("Volver", role: .cancel) {}
        }
        .alert("¿Enviar ahora?", isPresented: $confirmSendNow) {
            Button("Enviar ahora") { Task { await sendNow() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se enviará a \(msg?.recipientName ?? "") en los próximos segundos.")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private func partRow(index: Int, total: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if total > 1 {
                Text("\(index + 1) de \(total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
        }
    }

    private func recurrenceText(_ msg: ScheduledMessage) -> String {
        switch msg.recurrence {
        case .NONE: return ""
        case .DAILY: return "Todos los días"
        case .MONTHLY: return "Mensual"
        case .YEARLY: return "Cada año"
        case .WEEKLY:
            let names = ["", "lun", "mar", "mié", "jue", "vie", "sáb", "dom"]
            return "Semanal · " + msg.recurrenceDays.sorted().map { names[$0] }.joined(separator: ", ")
        }
    }

    private func load() async {
        do { detail = try await APIClient.shared.messageDetail(id: messageId) }
        catch { session.report(error) }
    }

    private func toggle() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.patchMessage(id: msg.id, PatchMessageBody(status: msg.status == .PAUSED ? .ACTIVE : .PAUSED))
            await load()
            await session.refreshMessages()
        } catch { session.report(error) }
    }

    private func sendNow() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.sendNow(id: msg.id)
            await load()
            await session.refreshMessages()
        } catch { session.report(error) }
    }

    private func cancel() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.cancelMessage(id: msg.id)
            await session.refreshMessages()
            dismiss()
        } catch { session.report(error) }
    }

    /// Posponer: reprograma la próxima ejecución a una nueva fecha (reusa el PATCH).
    private func snooze(to date: Date) async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.patchMessage(id: msg.id, PatchMessageBody(scheduledAt: date))
            await load()
            await session.refreshMessages()
        } catch { session.report(error) }
    }

    /// Hoy a las `hour`; si ya pasó, mañana a esa hora (nunca en el pasado).
    private func nextAt(hour: Int) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return today > Date().addingTimeInterval(120) ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    private func tomorrowAt(hour: Int) -> Date {
        let cal = Calendar.current
        let t = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: t) ?? t
    }

    private func duplicate() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            let created = try await APIClient.shared.duplicateMessage(id: msg.id)
            await session.refreshMessages()
            editCopy = created   // abre el editor sobre la copia para ajustar fecha/destinatario
        } catch { session.report(error) }
    }

    private func remove() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.deleteMessage(id: msg.id)
            await session.refreshMessages()
            dismiss()
        } catch { session.report(error) }
    }
}

/// Edición: fecha/hora, texto y recurrencia de un mensaje pendiente.
struct EditMessageView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let message: ScheduledMessage

    @State private var text: String = ""
    @State private var schedule = ScheduleConfig()
    @State private var instanceId: String = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mensaje") {
                    TextField("Texto", text: $text, axis: .vertical).lineLimit(1...4)
                }
                if session.instances.count > 1 {
                    Section("Instancia") {
                        Picker("Enviar desde", selection: $instanceId) {
                            ForEach(session.instances) { inst in
                                Text(inst.name).tag(inst.id)
                            }
                        }
                    }
                }
                Section("Envío") {
                    DatePicker("Fecha y hora", selection: $schedule.date, in: Date().addingTimeInterval(120)...)
                    Picker("Recurrencia", selection: $schedule.recurrence) {
                        Text("No se repite").tag(Recurrence.NONE)
                        Text("Todos los días").tag(Recurrence.DAILY)
                        Text("Semanal").tag(Recurrence.WEEKLY)
                        Text("Mensual").tag(Recurrence.MONTHLY)
                        Text("Cada año (cumpleaños)").tag(Recurrence.YEARLY)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Editar mensaje")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Guardar cambios") }
                    }
                    .disabled(busy)
                }
            }
            .onAppear {
                text = message.body ?? ""
                schedule.date = message.nextRunAt
                schedule.recurrence = message.recurrence
                schedule.recurrenceDays = Set(message.recurrenceDays)
                schedule.until = message.recurrenceUntil
                schedule.randomDelay = message.randomDelay
                instanceId = message.instanceId
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private func save() async {
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.patchMessage(id: message.id, PatchMessageBody(
                body: text.isEmpty ? nil : text,
                scheduledAt: schedule.date,
                recurrence: schedule.recurrence,
                recurrenceDays: schedule.recurrence == .WEEKLY ? schedule.recurrenceDays.sorted() : [],
                // conservar estos campos: antes se perdían al editar (recurrencia rota)
                recurrenceUntil: schedule.until,
                randomDelay: schedule.randomDelay,
                instanceId: instanceId != message.instanceId ? instanceId : nil
            ))
            await session.refreshMessages()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
