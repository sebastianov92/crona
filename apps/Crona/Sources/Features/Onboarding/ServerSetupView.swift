import SwiftUI

struct ServerSetupView: View {
    @Environment(SessionStore.self) private var session
    @State private var urlText = ""
    @State private var checking = false
    @State private var error: String?

    private var isHTTP: Bool { urlText.lowercased().hasPrefix("http://") }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("CronaLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360)
            Text("Dirección de tu servidor Crona")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TextField("https://catchapp.midominio.com", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                if isHTTP {
                    Label("Conexión sin cifrar (http). Úsala solo si confías en la red o estás en una VPN.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 420)
            .onAppear {
                // servidor guardado que no respondió al arrancar: prellenar y mostrar el motivo
                if urlText.isEmpty, let saved = session.serverURL?.absoluteString { urlText = saved }
                if error == nil { error = session.serverError }
            }

            Button {
                Task { await connect() }
            } label: {
                if checking { ProgressView().controlSize(.small) }
                else { Text("Conectar").frame(maxWidth: 200) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlText.isEmpty || checking)

            Spacer()
        }
        .padding()
    }

    private func connect() async {
        error = nil
        session.serverError = nil
        var text = urlText.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("http") { text = "https://\(text)" }
        guard let url = URL(string: text) else { error = "La URL no es válida."; return }
        checking = true
        defer { checking = false }
        do {
            try await session.setServer(url: url)
        } catch {
            self.error = "No se pudo conectar: \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}
