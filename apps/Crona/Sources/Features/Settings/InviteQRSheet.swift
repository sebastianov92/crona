import SwiftUI

/// Muestra el QR del deep-link de invitación (servidor + código). El usuario nuevo lo escanea con
/// la cámara del iPhone y la app abre con todo prellenado.
struct InviteQRSheet: View {
    let link: String
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let img = QRCode.image(from: link) {
                    Image(platform: img)
                        .interpolation(.none)   // QR nítido, sin difuminar los píxeles
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Escanéalo con la cámara del iPhone para conectar el servidor y registrarte.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(code)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)

                ShareLink(item: link) {
                    Label("Compartir enlace", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Invitación")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 460)
        #endif
    }
}
