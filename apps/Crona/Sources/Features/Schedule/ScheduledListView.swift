import SwiftUI

struct ScheduledListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos", contacts = "Contactos", groups = "Grupos", recurring = "Recurrentes", auto = "Automáticas"
        var id: String { rawValue }
    }

    @Environment(SessionStore.self) private var session
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showCompose = false
    @State private var selected: ScheduledMessage?

    private var filtered: [ScheduledMessage] {
        session.upcoming.filter { msg in
            switch filter {
            case .all: true
            case .contacts: msg.recipientKind == .CONTACT
            case .groups: msg.recipientKind == .GROUP
            case .recurring: msg.recurrence != .NONE
            case .auto: msg.isAutoReply
            }
        }
        .filter {
            search.isEmpty ||
            $0.recipientName.localizedCaseInsensitiveContains(search) ||
            ($0.body ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.hasDisconnectedInstance {
                    DisconnectedBanner()
                }
                filterChips
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "No tienes mensajes programados.",
                            systemImage: "clock.badge.questionmark",
                            description: Text("Toca + para crear el primero.")
                        )
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(filtered) { msg in
                        Button { selected = msg } label: { MessageRow(message: msg) }
                            .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Programados")
            .searchable(text: $search, prompt: "Buscar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCompose = true } label: { Label("Nuevo mensaje", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showCompose) { ComposeView() }
            .sheet(item: $selected) { msg in
                NavigationStack { MessageDetailView(messageId: msg.id) }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 520)
                    #endif
            }
            .refreshable { await session.refreshMessages() }
            .task { await session.refreshMessages() }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .cronaNewMessage)) { _ in
                showCompose = true   // "Nuevo mensaje" desde la menu bar (§9.4)
            }
            #endif
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.subheadline.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(filter == f ? Theme.accent.opacity(0.2) : Color.gray.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(filter == f ? Theme.accent : .primary)
                    }
                    .buttonStyle(.plain)
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
