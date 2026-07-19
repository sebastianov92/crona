import SwiftUI

struct HistoryView: View {
    @Environment(SessionStore.self) private var session
    @State private var search = ""

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
                    .listRowSeparator(.hidden)
                }
                ForEach(filtered) { item in
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
                }
            }
            .listStyle(.plain)
            .navigationTitle("Historial")
            .searchable(text: $search, prompt: "Buscar")
            .refreshable { await session.refreshHistory() }
            .task { await session.refreshHistory() }
        }
    }
}
