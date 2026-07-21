import SwiftUI

/// Pestaña Chats: conversaciones con la gente a la que ya programaste mensajes.
struct ChatsView: View {
    @Environment(SessionStore.self) private var session
    @State private var chats: [ChatSummary] = []
    @State private var loading = true
    @State private var selected: ChatSummary?

    var body: some View {
        NavigationStack {
            List {
                if chats.isEmpty && !loading {
                    ContentUnavailableView(
                        "Sin chats todavía",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Aquí aparecen las personas a las que ya programaste mensajes.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }
                ForEach(chats) { chat in
                    Button {
                        selected = chat
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: chat.name, pictureUrl: chat.pictureUrl, size: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.name).font(.headline)
                                Text(lastPreview(chat))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(chat.lastAt, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if chat.pendingCount > 0 {
                                    Text("\(chat.pendingCount)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Theme.accent, in: Capsule())
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await hide(chat) }
                        } label: {
                            Label("Quitar", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await hide(chat) }
                        } label: {
                            Label("Quitar de la lista", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if loading && chats.isEmpty { ProgressView() } }
            .navigationTitle("Chats")
            .refreshable { await load() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .catchappChatIncoming)) { _ in
                Task { await load() }
            }
            .navigationDestination(item: $selected) { chat in
                ChatDetailView(chat: chat)
            }
        }
    }

    private func lastPreview(_ chat: ChatSummary) -> String {
        guard let last = chat.last else { return "Sin mensajes todavía" }
        let text = messagePreview(type: last.type, body: last.body)
        return last.fromMe ? "Tú: \(text)" : text
    }

    private func load() async {
        do {
            chats = try await APIClient.shared.chats().items
        } catch { session.report(error) }
        loading = false
    }

    /// "Quitar" chat: se oculta hasta que haya un mensaje nuevo (enviado o recibido).
    private func hide(_ chat: ChatSummary) async {
        do {
            _ = try await APIClient.shared.hideChat(instanceId: chat.instanceId, jid: chat.jid)
            chats.removeAll { $0.id == chat.id }
        } catch { session.report(error) }
    }
}
