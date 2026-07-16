import SwiftUI

struct RegisterView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tu cuenta") {
                    TextField("Nombre", text: $name)
                    TextField("Email", text: $email)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Contraseña (mínimo 8)", text: $password)
                }
                Section {
                    TextField("Código de invitación", text: $inviteCode)
                        .autocorrectionDisabled()
                } footer: {
                    Text("El primer usuario del servidor no necesita invitación. Los demás piden el código al administrador.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Crear cuenta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await register() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Crear") }
                    }
                    .disabled(name.isEmpty || email.isEmpty || password.count < 8 || busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private func register() async {
        error = nil; busy = true
        defer { busy = false }
        do {
            try await session.register(email: email, password: password, name: name, inviteCode: inviteCode)
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
