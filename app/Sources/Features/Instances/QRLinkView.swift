import SwiftUI

/// Vinculación en vivo: QR (default en Mac) o código de emparejamiento (default en iPhone,
/// donde no puedes escanear tu propio QR). Ambos se refrescan por WS + polling de estado.
struct QRLinkView: View {
    enum Method: String, CaseIterable { case qr = "QR", code = "Código" }

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let instance: Instance
    var initialQR: String? = nil
    var initialPairingCode: String? = nil
    var prefillNumber: String = ""

    #if os(iOS)
    @State private var method: Method = .code
    #else
    @State private var method: Method = .qr
    #endif
    @State private var qrBase64: String?
    @State private var pairingCode: String?
    @State private var number = ""
    @State private var status: InstanceStatus = .CONNECTING
    @State private var loading = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Text(instance.name).font(.title2.bold())

            if status == .CONNECTED {
                connectedView
            } else {
                Picker("Método", selection: $method) {
                    ForEach(Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                if method == .qr { qrView } else { codeView }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 320)
                }
            }
        }
        .padding(24)
        .onAppear {
            qrBase64 = initialQR
            pairingCode = initialPairingCode
            number = prefillNumber
            if initialQR == nil && initialPairingCode == nil { Task { await requestQR() } }
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: session.lastQR?.qrBase64) { _, _ in
            if let last = session.lastQR, last.instanceId == instance.id { qrBase64 = last.qrBase64 }
        }
        .onChange(of: session.instances) { _, list in
            if let inst = list.first(where: { $0.id == instance.id }) { status = inst.status }
        }
    }

    private var connectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Theme.accent)
            Text("¡WhatsApp vinculado!").font(.headline)
            Button("Listo") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - QR

    private var qrView: some View {
        VStack(spacing: 14) {
            if let qrBase64, let image = decodeQR(qrBase64) {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().frame(width: 240, height: 240)
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

    // MARK: - Código de emparejamiento

    private var codeView: some View {
        VStack(spacing: 14) {
            if let pairingCode {
                Text(formatCode(pairingCode))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .kerning(2)
                    .textSelection(.enabled)
                    .padding(.vertical, 18).padding(.horizontal, 24)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text("En el teléfono del número a vincular: WhatsApp → Dispositivos vinculados → Vincular dispositivo → \"Vincular con el número de teléfono\" y escribe este código.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340)
                Button {
                    Task { await requestCode() }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Label("Nuevo código", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered)
            } else {
                Text("Número de WhatsApp a vincular, con código de país y sin +")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("593999999999", text: $number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button {
                    Task { await requestCode() }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Text("Generar código") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cleanNumber.count < 8 || loading)
            }
        }
    }

    private var cleanNumber: String { number.filter(\.isNumber) }

    private func formatCode(_ c: String) -> String {
        guard c.count == 8, !c.contains("-") else { return c }
        return "\(c.prefix(4))-\(c.suffix(4))"
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
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await APIClient.shared.instanceQR(id: instance.id)
            if let qr = r.qrBase64 { qrBase64 = qr }
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    private func requestCode() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await APIClient.shared.instanceQR(id: instance.id, number: cleanNumber)
            if let code = r.pairingCode {
                pairingCode = code
            } else {
                error = "Evolution no devolvió un código. Verifica el número (con código de país) e intenta de nuevo."
            }
            if let qr = r.qrBase64 { qrBase64 = qr }
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    /// El WS trae QR nuevo; el polling (4 s) detecta la conexión aunque el WS falle.
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
