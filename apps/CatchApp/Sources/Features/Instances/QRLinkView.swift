import SwiftUI

/// QR en vivo: muestra el QR actual y lo refresca cuando llega `qr.updated` por WebSocket.
struct QRLinkView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let instance: Instance
    var initialQR: String? = nil

    @State private var qrBase64: String?
    @State private var status: InstanceStatus = .CONNECTING
    @State private var loading = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Text(instance.name).font(.title2.bold())

            if status == .CONNECTED {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(Theme.accent)
                Text("¡WhatsApp vinculado!").font(.headline)
                Button("Listo") { dismiss() }.buttonStyle(.borderedProminent)
            } else {
                if let qrBase64, let image = decodeQR(qrBase64) {
                    image
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView().frame(width: 260, height: 260)
                }
                Text("Abre WhatsApp → Dispositivos vinculados → Vincular dispositivo y escanea este código.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
                Button {
                    Task { await requestQR() }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Label("Nuevo QR", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .onAppear {
            qrBase64 = initialQR
            if initialQR == nil { Task { await requestQR() } }
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: session.lastQR?.qrBase64) { _, newQR in
            if let last = session.lastQR, last.instanceId == instance.id { qrBase64 = last.qrBase64 }
        }
        .onChange(of: session.instances) { _, list in
            if let inst = list.first(where: { $0.id == instance.id }) { status = inst.status }
        }
    }

    private func decodeQR(_ base64: String) -> Image? {
        let raw = base64.contains(",") ? String(base64.split(separator: ",").last ?? "") : base64
        guard let data = Data(base64Encoded: raw) else { return nil }
        #if os(macOS)
        guard let img = NSImage(data: data) else { return nil }
        return Image(nsImage: img)
        #else
        guard let img = UIImage(data: data) else { return nil }
        return Image(uiImage: img)
        #endif
    }

    private func requestQR() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await APIClient.shared.instanceQR(id: instance.id)
            if let qr = r.qrBase64 { qrBase64 = qr }
        } catch { session.report(error) }
    }

    /// El WS trae el QR nuevo; el polling de estado (cada 4 s) detecta la conexión aunque el WS falle.
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled && status != .CONNECTED {
                try? await Task.sleep(for: .seconds(4))
                if let updated = try? await APIClient.shared.instanceStatus(id: instance.id) {
                    status = updated.status
                    if let i = session.instances.firstIndex(where: { $0.id == instance.id }) {
                        session.instances[i] = updated
                    }
                }
            }
        }
    }
}
