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

                    Section("Mensaje") {
                        if let mediaId = msg.mediaId {
                            MediaPreviewView(mediaId: mediaId, type: msg.type)
                        }
                        if let body = msg.body, !body.isEmpty {
                            Text(body)
                        }
                    }

                    Section("Programación") {
                        LabeledContent("Envío", value: scheduleLabel(msg.nextRunAt))
                        if msg.timezone != TimeZone.current.identifier {
                            LabeledContent("Zona horaria", value: timezoneLabel(msg.timezone))
                        }
                        if msg.recurrence != .NONE {
                            LabeledContent("Repite", value: recurrenceText(msg))
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
                            Button(msg.status == .PAUSED ? "Reanudar" : "Pausar") {
                                Task { await toggle() }
                            }
                            Button("Cancelar envío", role: .destructive) { confirmCancel = true }
                        }
                        Button("Duplicar") { Task { await duplicate() } }
                        if [.CANCELLED, .COMPLETED, .FAILED].contains(msg.status) {
                            Button("Eliminar", role: .destructive) { Task { await remove() } }
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
        .onReceive(NotificationCenter.default.publisher(for: .catchappLogUpdated)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showEdit, onDismiss: { Task { await load() } }) {
            if let msg { EditMessageView(message: msg) }
        }
        .confirmationDialog("¿Cancelar este envío?", isPresented: $confirmCancel) {
            Button("Cancelar envío", role: .destructive) { Task { await cancel() } }
        }
        .confirmationDialog(
            "Se enviará a \(msg?.recipientName ?? "") en los próximos segundos.",
            isPresented: $confirmSendNow, titleVisibility: .visible
        ) {
            Button("Enviar ahora") { Task { await sendNow() } }
        }
        .disabled(busy)
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

    private func duplicate() async {
        guard let msg else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.duplicateMessage(id: msg.id)
            await session.refreshMessages()
            dismiss()
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
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mensaje") {
                    TextField("Texto", text: $text, axis: .vertical).lineLimit(1...6)
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
                recurrenceDays: schedule.recurrence == .WEEKLY ? schedule.recurrenceDays.sorted() : []
            ))
            await session.refreshMessages()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
