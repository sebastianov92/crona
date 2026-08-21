import SwiftUI
import UniformTypeIdentifiers

/// Menú de stickers estilo WhatsApp: rejilla con la biblioteca del usuario (recientes primero).
/// Al elegir uno, descarga su webp y lo entrega como adjunto marcado como sticker.
struct StickerPickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Se llama con el sticker ya descargado como adjunto listo para el compose.
    let onPick: (Attachment) -> Void

    @State private var stickers: [StickerAsset] = []
    @State private var loading = true
    @State private var uploading = false
    @State private var error: String?
    @State private var showImporter = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if stickers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(stickers) { sticker in
                                StickerThumb(mediaId: sticker.mediaId)
                                    .onTapGesture { Task { await pick(sticker) } }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Task { await remove(sticker) }
                                        } label: {
                                            Label("Quitar", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Mis stickers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        if uploading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus") }
                    }
                    .disabled(uploading)
                    .help("Añadir sticker desde archivo")
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.webP, .png, .jpeg]) { result in
                if case .success(let url) = result { Task { await add(url) } }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "face.smiling")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Aún no tienes stickers")
                .font(.headline)
            Text("Activa \"Guardar mis stickers\" en Ajustes y envíate stickers a ti mismo por WhatsApp para que aparezcan aquí. También puedes añadir imágenes con el botón +.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { stickers = try await APIClient.shared.stickers().items }
        catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    /// Descarga el webp del sticker elegido y lo entrega como adjunto; lo marca como usado.
    private func pick(_ sticker: StickerAsset) async {
        do {
            let data = try await APIClient.shared.mediaData(id: sticker.mediaId)
            let att = Attachment(data: data, fileName: "sticker.webp",
                                 mimeType: "image/webp", asSticker: true)
            _ = try? await APIClient.shared.markStickerUsed(id: sticker.id)
            onPick(att)
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            error = "Sin permiso para leer el archivo seleccionado."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/webp"
            uploading = true; defer { uploading = false }
            _ = try await APIClient.shared.uploadSticker(
                data: data, fileName: url.lastPathComponent, mimeType: mime
            )
            await load()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove(_ sticker: StickerAsset) async {
        do {
            _ = try await APIClient.shared.deleteSticker(id: sticker.id)
            stickers.removeAll { $0.id == sticker.id }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Miniatura de un sticker de la biblioteca (webp cargado por MediaCache).
private struct StickerThumb: View {
    let mediaId: String
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12))
            if let image {
                Image(platform: image).resizable().scaledToFit().padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 84, height: 84)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .task(id: mediaId) { image = await MediaCache.image(for: mediaId) }
    }
}
