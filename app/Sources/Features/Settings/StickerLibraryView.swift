import SwiftUI

/// Gestión de la biblioteca de stickers desde Ajustes: verlos y borrarlos.
struct StickerLibraryView: View {
    @Environment(SessionStore.self) private var session
    @State private var stickers: [StickerAsset] = []
    @State private var loading = true
    @State private var pendingDelete: StickerAsset?

    private let cols = [GridItem(.adaptive(minimum: 90), spacing: 10)]

    var body: some View {
        ScrollView {
            if stickers.isEmpty && !loading {
                ContentUnavailableView(
                    "Sin stickers",
                    systemImage: "face.smiling",
                    description: Text("Guarda stickers desde el editor de mensajes (botón Sticker → subir).")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(stickers) { s in
                        StickerThumb(mediaId: s.mediaId)
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = s } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button { pendingDelete = s } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.white, .red)
                                        .background(Circle().fill(.black.opacity(0.15)))
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                    }
                }
                .padding()
            }
        }
        .overlay { if loading && stickers.isEmpty { ProgressView() } }
        .navigationTitle("Biblioteca de stickers")
        .refreshable { await load() }
        .task { await load() }
        .alert("¿Borrar este sticker?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Borrar", role: .destructive) {
                if let s = pendingDelete { Task { await delete(s) } }
                pendingDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Se quita de tu biblioteca. No afecta a mensajes ya enviados.")
        }
    }

    private func load() async {
        do { stickers = try await APIClient.shared.stickers().items } catch { session.report(error) }
        loading = false
    }

    private func delete(_ s: StickerAsset) async {
        stickers.removeAll { $0.id == s.id }   // optimista
        do { _ = try await APIClient.shared.deleteSticker(id: s.id) }
        catch { session.report(error); await load() }
    }
}

private struct StickerThumb: View {
    let mediaId: String
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image { Image(platform: image).resizable().scaledToFit() }
            else { ProgressView() }
        }
        .frame(width: 90, height: 90)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .task(id: mediaId) { image = await MediaCache.image(for: mediaId) }
    }
}
