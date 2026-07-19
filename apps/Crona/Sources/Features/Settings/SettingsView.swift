import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationStack {
            Form {
                if let user = session.user {
                    Section("Cuenta") {
                        LabeledContent("Nombre", value: user.name)
                        LabeledContent("Email", value: user.email)
                        LabeledContent("Rol", value: user.role == .ADMIN ? "Administrador" : "Usuario")
                    }
                }

                Section("WhatsApp") {
                    NavigationLink("Instancias") { InstanceListView() }
                }

                Section("Notificaciones") {
                    NavigationLink("Notificaciones (ntfy)") { NtfySettingsView() }
                }

                if session.isAdmin {
                    Section("Administración") {
                        NavigationLink("Servidor Evolution") { AdminSettingsView() }
                        NavigationLink("Usuarios e invitaciones") { AdminUsersView() }
                    }
                }

                Section {
                    LabeledContent("Servidor", value: session.serverURL?.absoluteString ?? "—")
                    Button("Cerrar sesión", role: .destructive) {
                        Task { await session.logout() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajustes")
        }
    }
}

struct NtfySettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var topic = ""
    @State private var token = ""
    @State private var notifyOnSent = false
    @State private var saved = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Topic (ej. crona-seb-a8k2x1)", text: $topic)
                    .autocorrectionDisabled()
                SecureField("Token (solo si tu servidor ntfy usa auth)", text: $token)
                Toggle("Notificar también envíos exitosos", isOn: $notifyOnSent)
            } footer: {
                Text("Instala la app ntfy del App Store y suscríbete a tu topic. Los fallos de envío y desconexiones llegan siempre; los envíos exitosos solo si activas la opción. El topic funciona como secreto: usa uno difícil de adivinar.")
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Guardar cambios") }
                }
                if topic.isEmpty {
                    Button("Generar topic aleatorio") {
                        let chars = "abcdefghjkmnpqrstuvwxyz23456789"
                        let suffix = String((0..<6).compactMap { _ in chars.randomElement() })
                        let name = (session.user?.name ?? "user")
                            .lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                        topic = "crona-\(name.prefix(10))-\(suffix)"
                    }
                }
                if saved { Label("Guardado", systemImage: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notificaciones")
        .onAppear {
            topic = session.user?.ntfyTopic ?? ""
            notifyOnSent = session.user?.notifyOnSent ?? false
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        do {
            session.user = try await APIClient.shared.patchMe(
                ntfyTopic: .some(topic.isEmpty ? nil : topic),
                ntfyToken: .some(token.isEmpty ? nil : token),
                notifyOnSent: notifyOnSent
            )
            saved = true
        } catch { session.report(error) }
    }
}

struct AdminSettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var evolutionBaseUrl = ""
    @State private var apiKey = ""
    @State private var keySet = false
    @State private var ntfyBaseUrl = "https://ntfy.sh"
    @State private var testResult: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Evolution API") {
                TextField("URL (ej. http://evolution-api:8080)", text: $evolutionBaseUrl)
                    .autocorrectionDisabled()
                SecureField(keySet ? "API key global (configurada — escribir para cambiar)" : "API key global", text: $apiKey)
            }
            Section("ntfy") {
                TextField("URL del servidor ntfy", text: $ntfyBaseUrl)
                    .autocorrectionDisabled()
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Guardar cambios") }
                }
                Button("Probar conexión") { Task { await test() } }
                    .disabled(busy)
                if let testResult {
                    Text(testResult)
                        .foregroundStyle(testResult.hasPrefix("✅") ? Theme.accent : .red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Servidor Evolution")
        .task {
            if let s = try? await APIClient.shared.adminSettings() {
                evolutionBaseUrl = s.evolutionBaseUrl
                ntfyBaseUrl = s.ntfyBaseUrl
                keySet = s.evolutionGlobalApiKeySet
            }
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        do {
            let s = try await APIClient.shared.putAdminSettings(
                evolutionBaseUrl: evolutionBaseUrl,
                evolutionGlobalApiKey: apiKey.isEmpty ? nil : apiKey,
                ntfyBaseUrl: ntfyBaseUrl
            )
            keySet = s.evolutionGlobalApiKeySet
            apiKey = ""
            testResult = "Guardado."
        } catch { session.report(error) }
    }

    private func test() async {
        busy = true; defer { busy = false }
        do {
            let r = try await APIClient.shared.testAdminSettings()
            testResult = r.ok ? "✅ Evolution v\(r.version)" : "❌ Versión no soportada: \(r.version) (se requiere 2.x)"
        } catch {
            testResult = "❌ \((error as? APIError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}

struct AdminUsersView: View {
    @Environment(SessionStore.self) private var session
    @State private var users: [User] = []
    @State private var invite: InviteResponse?

    var body: some View {
        Form {
            Section("Usuarios") {
                ForEach(users) { u in
                    LabeledContent(u.name) {
                        Text(u.role == .ADMIN ? "Admin" : u.email).font(.caption)
                    }
                }
            }
            Section("Invitaciones") {
                Button("Crear código de invitación") {
                    Task { invite = try? await APIClient.shared.createInvite() }
                }
                if let invite {
                    LabeledContent("Código") {
                        Text(invite.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("Expira", value: invite.expiresAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usuarios")
        .task { users = (try? await APIClient.shared.adminUsers().items) ?? [] }
    }
}
