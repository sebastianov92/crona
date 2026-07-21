import SwiftUI

struct AutoRepliesView: View {
    @Environment(SessionStore.self) private var session
    @State private var rules: [AutoReply] = []
    @State private var editing: AutoReply?
    @State private var showCreate = false

    var body: some View {
        Form {
            Section {
                if rules.isEmpty {
                    Text("Sin reglas. Crea una para responder o recibir avisos cuando te escriban.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    AutoReplyRow(rule: rule,
                                 instanceName: session.instances.count > 1
                                     ? session.instances.first { $0.id == rule.instanceId }?.name
                                     : nil) { enabled in
                        Task {
                            _ = try? await APIClient.shared.setAutoReplyEnabled(id: rule.id, enabled: enabled)
                            await load()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = rule }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                _ = try? await APIClient.shared.deleteAutoReply(id: rule.id)
                                await load()
                            }
                        } label: { Label("Eliminar", systemImage: "trash") }.tint(.red)
                    }
                }
            } footer: {
                Text("Las respuestas salen con un retraso aleatorio de 1 a 5 minutos (parece natural y evita detección) y máximo una vez por contacto por ventana de espera.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Respuestas automáticas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("Nueva regla", systemImage: "plus") }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            AutoReplyEditView(rule: nil)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { rule in
            AutoReplyEditView(rule: rule)
        }
    }

    private func load() async {
        rules = (try? await APIClient.shared.autoReplies().items) ?? []
    }
}

private let daysShort = ["", "lun", "mar", "mié", "jue", "vie", "sáb", "dom"]

struct AutoReplyRow: View {
    let rule: AutoReply
    var instanceName: String? = nil
    let onToggle: (Bool) -> Void

    private var ruleTitle: String {
        let who = rule.contactName.map { "Si \($0)" } ?? "Si alguien"
        let what = rule.keyword.map { "dice \"\($0)\"" } ?? "escribe"
        return "\(who) \(what)"
    }

    var body: some View {
        HStack {
            Image(systemName: rule.action == .REPLY ? "arrowshape.turn.up.left.fill" : "bell.badge.fill")
                .foregroundStyle(rule.enabled ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleTitle)
                    .font(.body)
                Text(rule.action == .REPLY ? "Responder: \(rule.replyText ?? "")" : "Avisarme por ntfy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let from = rule.activeFromHour, let to = rule.activeToHour {
                    Text("Activa de \(from):00 a \(to):00")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !rule.activeDays.isEmpty {
                    Text("Días: " + rule.activeDays.sorted().map { daysShort[$0] }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let instanceName {
                    Text("Número: \(instanceName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Toggle("", isOn: .init(get: { rule.enabled }, set: onToggle))
                .labelsHidden()
        }
    }
}

struct AutoReplyEditView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let rule: AutoReply?

    @State private var instanceId: String?
    @State private var action: AutoReplyAction = .REPLY
    @State private var contact: Recipient?
    @State private var keyword = ""
    @State private var replyText = ""
    @State private var limitHours = false
    @State private var fromHour = 22
    @State private var toHour = 7
    @State private var limitDays = false
    @State private var selectedDays: Set<Int> = []

    private static let dayNames = [(1, "L"), (2, "M"), (3, "X"), (4, "J"), (5, "V"), (6, "S"), (7, "D")]
    @State private var cooldown = 60
    @State private var busy = false
    @State private var error: String?
    @State private var showContactPicker = false

    var body: some View {
        NavigationStack {
            Form {
                if session.instances.count > 1 {
                    Section("Número que responde") {
                        if let rule {
                            // la instancia de una regla existente no se cambia (crea otra regla si la necesitas en otro número)
                            LabeledContent("Instancia",
                                           value: session.instances.first { $0.id == rule.instanceId }?.name ?? "—")
                        } else {
                            Picker("Instancia", selection: $instanceId) {
                                ForEach(session.instances) { inst in
                                    Text(inst.name).tag(Optional(inst.id))
                                }
                            }
                        }
                    }
                }

                Section("Cuando escriba") {
                    Button {
                        showContactPicker = true
                    } label: {
                        HStack {
                            if let contact {
                                AvatarView(name: contact.displayName, pictureUrl: contact.pictureUrl, size: 30)
                                Text(contact.displayName)
                            } else {
                                Label("Cualquier contacto", systemImage: "person.2")
                            }
                            Spacer()
                            if contact != nil {
                                Button {
                                    contact = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    TextField("ej. precio, cita, hola…", text: $keyword, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(8)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                } header: {
                    Text("Palabra clave")
                } footer: {
                    Text("Deja vacío para cualquier mensaje.")
                }
                Section("Acción") {
                    Picker("Acción", selection: $action) {
                        Text("Responder automáticamente").tag(AutoReplyAction.REPLY)
                        Text("Avisarme por ntfy (prioridad alta)").tag(AutoReplyAction.NOTIFY)
                    }
                    if action == .REPLY {
                        TextField("Texto de respuesta", text: $replyText, axis: .vertical)
                            .lineLimit(2...5)
                        Text("Variables: {nombre} · {primer_nombre} (de quien escribe) · {fecha} · {dia}.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Solo en cierto horario", isOn: $limitHours)
                    if limitHours {
                        Picker("Desde", selection: $fromHour) { ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) } }
                        Picker("Hasta", selection: $toHour) { ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) } }
                    }
                    Toggle("Solo ciertos días", isOn: $limitDays)
                    if limitDays {
                        HStack(spacing: 6) {
                            ForEach(Self.dayNames, id: \.0) { (num, label) in
                                Button {
                                    if selectedDays.contains(num) { selectedDays.remove(num) }
                                    else { selectedDays.insert(num) }
                                } label: {
                                    Text(label)
                                        .font(.subheadline.bold())
                                        .frame(width: 32, height: 32)
                                        .background(selectedDays.contains(num) ? Theme.accent : Color.gray.opacity(0.15), in: Circle())
                                        .foregroundStyle(selectedDays.contains(num) ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Picker("Máx. 1 vez por contacto cada", selection: $cooldown) {
                        Text("15 min").tag(15)
                        Text("1 hora").tag(60)
                        Text("4 horas").tag(240)
                        Text("24 horas").tag(1440)
                    }
                } footer: {
                    Text("Ej. fuera de horario: de 22:00 a 7:00 responde \"Te escribo mañana\".")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? "Nueva regla" : "Editar regla")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Guardar") }
                    }
                    .disabled(busy || (action == .REPLY && replyText.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear { applyRule() }
            .sheet(isPresented: $showContactPicker) {
                if let iid = rule?.instanceId ?? instanceId ?? session.activeInstance?.id {
                    RecipientPickerView(instanceId: iid) { picked in
                        contact = picked.first
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func applyRule() {
        if instanceId == nil { instanceId = rule?.instanceId ?? session.activeInstance?.id }
        guard let rule else { return }
        action = rule.action
        if let jid = rule.contactJid {
            contact = Recipient(id: jid, jid: jid, displayName: rule.contactName ?? jid,
                                alias: nil, pictureUrl: nil, kind: .CONTACT, phoneNumber: nil)
        }
        keyword = rule.keyword ?? ""
        replyText = rule.replyText ?? ""
        limitHours = rule.activeFromHour != nil
        fromHour = rule.activeFromHour ?? 22
        toHour = rule.activeToHour ?? 7
        limitDays = !rule.activeDays.isEmpty
        selectedDays = Set(rule.activeDays)
        cooldown = rule.cooldownMinutes
    }

    private func save() async {
        guard let instanceId = rule?.instanceId ?? instanceId ?? session.activeInstance?.id else {
            error = "Primero vincula una instancia de WhatsApp."
            return
        }
        busy = true; defer { busy = false }
        let body = AutoReplyBody(
            instanceId: instanceId,
            action: action,
            contactJid: contact?.jid,
            contactName: contact?.displayName,
            keyword: keyword.trimmingCharacters(in: .whitespaces).isEmpty ? nil : keyword,
            replyText: action == .REPLY ? replyText : nil,
            activeFromHour: limitHours ? fromHour : nil,
            activeToHour: limitHours ? toHour : nil,
            activeDays: limitDays ? selectedDays.sorted() : [],
            timezone: TimeZone.current.identifier,
            cooldownMinutes: cooldown,
            enabled: rule?.enabled ?? true
        )
        do {
            if let rule {
                _ = try await APIClient.shared.patchAutoReply(id: rule.id, body)
            } else {
                _ = try await APIClient.shared.createAutoReply(body)
            }
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
