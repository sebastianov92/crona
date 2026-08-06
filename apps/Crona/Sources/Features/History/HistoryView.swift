import SwiftUI

/// Referencia a un mensaje por id para abrir su detalle desde el historial.
private struct MsgRef: Identifiable { let id: String }

struct HistoryView: View {
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "Todos", failed = "Fallidos", sent = "Enviados"
        var id: String { rawValue }
    }

    @Environment(SessionStore.self) private var session
    @State private var search = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var openMsg: MsgRef?
    @State private var pendingDelete: HistoryItem?
    @State private var pendingRemote: HistoryItem?

    /// ¿Se puede borrar en el WhatsApp del destinatario? Solo envíos exitosos < ~2 días.
    private func canDeleteRemote(_ item: HistoryItem) -> Bool {
        guard item.status == .SENT || item.status == .DELIVERED || item.status == .READ else { return false }
        return item.runAt.timeIntervalSinceNow > -2 * 24 * 3600
    }

    private func matchesStatus(_ item: HistoryItem, _ f: StatusFilter) -> Bool {
        switch f {
        case .all: return true
        case .failed: return item.status == .FAILED
        case .sent: return item.status == .SENT || item.status == .DELIVERED || item.status == .READ
        }
    }

    private func count(_ f: StatusFilter) -> Int { session.history.filter { matchesStatus($0, f) }.count }
    private var failedCount: Int { count(.failed) }

    private var filtered: [HistoryItem] {
        session.history.filter { matchesStatus($0, statusFilter) }.filter {
            search.isEmpty ||
            $0.recipientName.localizedCaseInsensitiveContains(search) ||
            ($0.body ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            statusChips
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
                    // allowsFullSwipe:false + confirmación: un arrastre nunca borra solo.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                        .tint(.red)   // el tint verde global de la app pisa el rojo del rol destructivo
                        // Borrar el mensaje ya entregado en el chat del destinatario (ventana ~2 días).
                        if canDeleteRemote(item) {
                            Button { pendingRemote = item } label: {
                                Label("Eliminar de WhatsApp", systemImage: "trash.slash")
                            }
                            .tint(.orange)
                        }
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
            .alert(
                "¿Borrar este envío del historial?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Borrar", role: .destructive) {
                    if let item = pendingDelete { Task { await delete(item) } }
                    pendingDelete = nil
                }
                Button("Cancelar", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Se quita del historial. No afecta al mensaje programado.")
            }
            .alert(
                "¿Eliminar de WhatsApp?",
                isPresented: Binding(get: { pendingRemote != nil }, set: { if !$0 { pendingRemote = nil } })
            ) {
                Button("Eliminar", role: .destructive) {
                    if let item = pendingRemote { Task { await deleteRemote(item) } }
                    pendingRemote = nil
                }
                Button("Cancelar", role: .cancel) { pendingRemote = nil }
            } message: {
                Text("Borra el mensaje en el chat del destinatario (\"Eliminar para todos\"). Solo funciona dentro de las ~48 h del envío.")
            }
            } // VStack
        }
    }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StatusFilter.allCases) { f in
                    // "Fallidos" solo si hay alguno
                    if f != .failed || failedCount > 0 {
                        let n = count(f)
                        Button { statusFilter = f } label: {
                            HStack(spacing: 6) {
                                Text(f.rawValue)
                                if f == .failed {
                                    Text("\(n)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.red.opacity(0.22), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.subheadline.weight(statusFilter == f ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(statusFilter == f ? Theme.accent.opacity(0.2) : Color.gray.opacity(0.12), in: Capsule())
                            .foregroundStyle(statusFilter == f ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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

    /// "Eliminar para todos" en el chat del destinatario. No toca el historial local.
    private func deleteRemote(_ item: HistoryItem) async {
        do {
            _ = try await APIClient.shared.deleteMessageForEveryone(logId: item.id)
        } catch { session.report(error) }
    }
}
