import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showRegister = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("CronaLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 340)
            Text("Inicia sesión").font(.title.bold())

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Contraseña", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await login() } }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 360)

            Button {
                Task { await login() }
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Text("Entrar").frame(maxWidth: 160) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || busy)

            Button("Crear cuenta") { showRegister = true }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

            Button("Cambiar servidor") {
                Keychain.delete("serverURL")
                session.phase = .needsServer
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showRegister) { RegisterView() }
        .onAppear { if email.isEmpty { focus = .email } }
    }

    private func login() async {
        error = nil; busy = true
        defer { busy = false }
        do { try await session.login(email: email, password: password) }
        catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }
}
