import SwiftUI

/// Referencia a un mensaje por id para abrir su detalle desde el historial.
private struct MsgRef: Identifiable { let id: String }

struct HistoryView: View {
    @Environment(SessionStore.self) private var session
    @State private var search = ""
    @State private var openMsg: MsgRef?

    private var filtered: [HistoryItem] {
        session.history.filter {
            search.isEmpty ||
            $0.recipientName.localizedCaseInsensitiveContains(search) ||
            ($0.body ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Aún no hay envíos en el historial.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }
                ForEach(filtered) { item in
                    Button { openMsg = MsgRef(id: item.scheduledMessageId) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: item.recipientName, pictureUrl: item.recipientPictureUrl)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.recipientName).font(.headline)
                                Text(item.error ?? messagePreview(type: item.type, body: item.body))
                                    .font(.subheadline)
                                    .foregroundStyle(item.error != nil ? .red : .secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if item.type == .IMAGE, let mediaId = item.mediaId {
                                MediaThumbView(mediaId: mediaId)
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(scheduleLabel(item.runAt)).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 3) {
                                    Image(systemName: item.status.systemImage)
                                    Text(item.status.label).font(.caption2)
                                }
                                .font(.caption)
                                .foregroundStyle(item.status.tint)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Reenviar un envío fallido sin buscar el mensaje: 1 swipe.
                    .swipeActions(edge: .leading) {
                        if item.status == .FAILED {
                            Button { Task { await retry(item) } } label: {
                                Label("Reintentar", systemImage: "arrow.clockwise")
                            }
                            .tint(Theme.accent)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await delete(item) }
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                        .tint(.red)   // el tint verde global de la app pisa el rojo del rol destructivo
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Historial")
            .searchable(text: $search, prompt: "Buscar")
            .refreshable { await session.refreshHistory() }
            .task { await session.refreshHistory() }
            .sheet(item: $openMsg) { ref in
                NavigationStack { MessageDetailView(messageId: ref.id) }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 520)
                    #endif
            }
        }
    }

    /// Reenvía un envío fallido: reusa "enviar ahora" del mensaje padre.
    private func retry(_ item: HistoryItem) async {
        do {
            _ = try await APIClient.shared.sendNow(id: item.scheduledMessageId)
            await session.refreshMessages()
            await session.refreshHistory()
        } catch { session.report(error) }
    }

    private func delete(_ item: HistoryItem) async {
        session.history.removeAll { $0.id == item.id }   // optimista
        do {
            _ = try await APIClient.shared.deleteLog(id: item.id)
        } catch {
            session.report(error)
            await session.refreshHistory()
        }
    }
}
