import SwiftUI

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Cache en memoria de previews de media (se pierde al cerrar la app — suficiente para v1).
@MainActor
enum MediaCache {
    private static var images: [String: PlatformImage] = [:]
    private static var failed: Set<String> = []

    static func image(for mediaId: String) async -> PlatformImage? {
        if let hit = images[mediaId] { return hit }
        if failed.contains(mediaId) { return nil }
        guard let data = try? await APIClient.shared.mediaData(id: mediaId),
              let img = PlatformImage(data: data) else {
            failed.insert(mediaId)
            return nil
        }
        images[mediaId] = img
        return img
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

/// Preview grande (detalle): imagen completa; video/PDF muestran placeholder con icono.
struct MediaPreviewView: View {
    let mediaId: String
    let type: MessageType

    @State private var image: PlatformImage?
    @State private var loading = true

    var body: some View {
        Group {
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if loading && type == .IMAGE {
                ProgressView().frame(height: 120)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: type == .VIDEO ? "video.fill" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                    Text(type == .VIDEO ? "Video adjunto" : "Documento adjunto")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .task(id: mediaId) {
            loading = true
            if type == .IMAGE { image = await MediaCache.image(for: mediaId) }
            loading = false
        }
    }
}

/// Miniatura cuadrada (filas de historial).
struct MediaThumbView: View {
    let mediaId: String
    var size: CGFloat = 44

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platform: image).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: mediaId) { image = await MediaCache.image(for: mediaId) }
    }
}
