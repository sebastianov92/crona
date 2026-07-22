import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// Ajustes de creación de grupos: foto por defecto y plantillas del mensaje inicial.
struct GroupSettingsView: View {
    @Environment(SessionStore.self) private var session

    @State private var picked: Data?
    @State private var busy = false
    @State private var showFileImporter = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    GroupPictureView(data: picked, mediaId: session.user?.defaultGroupPictureMediaId)
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Elegir foto…") {
                            #if os(iOS)
                            showPhotoPicker = true
                            #else
                            showFileImporter = true
                            #endif
                        }
                        if session.user?.defaultGroupPictureMediaId != nil {
                            Button("Quitar foto", role: .destructive) { Task { await save(mediaId: nil) } }
                                .font(.caption)
                        }
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Foto por defecto")
            } footer: {
                Text("Se usa como foto de los grupos nuevos. Al crear un grupo puedes cambiarla solo para ese grupo.")
            }

            Section {
                NavigationLink("Plantillas del mensaje inicial") {
                    TemplatesView(kind: .GROUP_INITIAL)
                }
                NavigationLink("Grupos creados") { GroupsListView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Creación de grupos")
        #if os(iOS)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                picked = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                await upload()
            }
        }
        #endif
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.jpeg, .png]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                picked = try? Data(contentsOf: url)
                Task { await upload() }
            }
        }
    }

    private func upload() async {
        guard let picked else { return }
        busy = true; defer { busy = false }
        do {
            let up = try await APIClient.shared.uploadMedia(
                data: picked, fileName: "grupo.jpg", mimeType: "image/jpeg")
            await save(mediaId: up.mediaId)
        } catch { session.report(error) }
    }

    private func save(mediaId: String?) async {
        do {
            session.user = try await APIClient.shared.patchMe(defaultGroupPictureMediaId: .some(mediaId))
            if mediaId == nil { picked = nil }
        } catch { session.report(error) }
    }
}
