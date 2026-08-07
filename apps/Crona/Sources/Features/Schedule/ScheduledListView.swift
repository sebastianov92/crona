import SwiftUI

struct ScheduledListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos", paused = "Pausados", contacts = "Contactos", groups = "Grupos", recurring = "Recurrentes", auto = "Automáticas"
        var id: String { rawValue }
    }

    @Environment(SessionStore.self) private var session
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showCompose = false
    @State private var showInstances = false
    @State private var selected: ScheduledMessage?

    private var pausedCount: Int { session.upcoming.filter { $0.status == .PAUSED }.count }

    private func count(for f: Filter) -> Int {
        session.upcoming.filter { matches($0, f) }.count
    }

    private func matches(_ msg: ScheduledMessage, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .paused: return msg.status == .PAUSED
        case .contacts: return msg.recipientKind == .CONTACT
        case .groups: return msg.recipientKind == .GROUP
        case .recurring: return msg.recurrence != .NONE
        case .auto: return msg.isAutoReply
        }
    }

    /// Programados agrupados por día natural (de nextRunAt), ordenados por fecha.
    private var groupedByDay: [(key: String, items: [ScheduledMessage])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.nextRunAt) }
        return groups.keys.sorted().map { day in
            (dayLabel(day), (groups[day] ?? []).sorted { $0.nextRunAt < $1.nextRunAt })
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Hoy" }
        if cal.isDateInTomorrow(date) { return "Mañana" }
        if cal.isDateInYesterday(date) { return "Ayer" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: date).capitalized
    }

    private var filtered: [ScheduledMessage] {
        session.upcoming.filter { matches($0, filter) }
        .filter {
            search.isEmpty ||
            $0.recipientName.localizedCaseInsensitiveContains(search) ||
            ($0.body ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Guía de primeros pasos: se oculta sola al conectar WhatsApp y programar el 1º.
                OnboardingChecklist(
                    onConnect: { showInstances = true },
                    onCompose: { showCompose = true }
                )
                filterChips
                List {
                    // Agrupado por día: cabeceras Hoy / Mañana / fecha para escanear la carga.
                    ForEach(groupedByDay, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.items) { msg in
                                Button { selected = msg } label: { MessageRow(message: msg) }
                                    .buttonStyle(.plain)
                                    // Acciones rápidas sin abrir el detalle. Cancelar no es full-swipe:
                                    // hace falta tocar el botón (evita cancelar por un arrastre accidental).
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if msg.status == .ACTIVE || msg.status == .PAUSED {
                                            Button(role: .destructive) { Task { await cancelMsg(msg) } } label: {
                                                Label("Cancelar", systemImage: "xmark.circle")
                                            }
                                            .tint(.red)
                                            Button { Task { await toggleMsg(msg) } } label: {
                                                Label(msg.status == .PAUSED ? "Reanudar" : "Pausar",
                                                      systemImage: msg.status == .PAUSED ? "play.fill" : "pause.fill")
                                            }
                                            .tint(.orange)
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button { Task { await duplicateMsg(msg) } } label: {
                                            Label("Duplicar", systemImage: "plus.square.on.square")
                                        }
                                        .tint(Theme.accent)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // Empty state como overlay (no como fila de la List: ahí el botón se estiraba).
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label("No tienes mensajes programados.", systemImage: "clock.badge.questionmark")
                        } description: {
                            Text("Programa un mensaje para que se envíe solo a la hora que quieras.")
                        } actions: {
                            Button { showCompose = true } label: { Label("Programar mensaje", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                            if !session.instances.contains(where: { $0.status == .CONNECTED }) {
                                Button { showInstances = true } label: { Label("Conectar WhatsApp", systemImage: "qrcode") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Programados")
            .searchable(text: $search, prompt: "Buscar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCompose = true } label: { Label("Nuevo mensaje", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showCompose) { ComposeView() }
            .sheet(isPresented: $showInstances) { InstancesSheet() }
            .sheet(item: $selected) { msg in
                NavigationStack { MessageDetailView(messageId: msg.id) }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 520)
                    #endif
            }
            .refreshable { await session.refreshMessages() }
            .task { await session.refreshMessages() }
        }
    }

    // MARK: - Acciones rápidas (swipe) — reusan la API del detalle

    private func cancelMsg(_ msg: ScheduledMessage) async {
        do {
            _ = try await APIClient.shared.cancelMessage(id: msg.id)
            await session.refreshMessages()
        } catch { session.report(error) }
    }

    private func toggleMsg(_ msg: ScheduledMessage) async {
        do {
            _ = try await APIClient.shared.patchMessage(
                id: msg.id, PatchMessageBody(status: msg.status == .PAUSED ? .ACTIVE : .PAUSED))
            await session.refreshMessages()
        } catch { session.report(error) }
    }

    private func duplicateMsg(_ msg: ScheduledMessage) async {
        do {
            let created = try await APIClient.shared.duplicateMessage(id: msg.id)
            await session.refreshMessages()
            selected = created   // abre la copia (con su botón Editar) en vez de enterrarla
        } catch { session.report(error) }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    // "Pausados" solo se muestra si hay alguno (no ocupar espacio sin motivo)
                    if f != .paused || pausedCount > 0 {
                        let n = count(for: f)
                        Button {
                            filter = f
                        } label: {
                            HStack(spacing: 6) {
                                Text(f.rawValue)
                                if f == .paused || f == .recurring {
                                    Text("\(n)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(filter == f ? Theme.accent.opacity(0.25) : Color.gray.opacity(0.2), in: Capsule())
                                }
                            }
                            .font(.subheadline.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(filter == f ? Theme.accent.opacity(0.2) : Color.gray.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(filter == f ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

struct MessageRow: View {
    let message: ScheduledMessage

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: message.recipientName, pictureUrl: message.recipientPictureUrl)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.recipientName).font(.headline)
                Text(messagePreview(type: message.type, body: message.body))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if message.partCount > 1 {
                    Label("1 de \(message.partCount) mensajes", systemImage: "rectangle.stack")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    if message.isAutoReply {
                        Image(systemName: "arrowshape.turn.up.left").font(.caption2)
                    }
                    if message.recurrence != .NONE {
                        Image(systemName: recurrenceIcon).font(.caption2)
                    }
                    Text(scheduleLabel(message.nextRunAt)).font(.caption)
                }
                .foregroundStyle(Theme.accent)
                Image(systemName: message.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(message.status.tint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct DisconnectedBanner: View {
    var body: some View {
        Label("Tu WhatsApp está desconectado — los envíos fallarán. Re-escanea el QR.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.15))
            .foregroundStyle(.red)
    }
}
