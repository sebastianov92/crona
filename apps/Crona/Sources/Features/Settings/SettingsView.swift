import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Apariencia") {
                    Picker("Tema", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.rawValue) { a in
                            Text(a.label).tag(a.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let user = session.user {
                    Section("Cuenta") {
                        LabeledContent("Nombre", value: user.name)
                        LabeledContent("Email", value: user.email)
                        LabeledContent("Rol", value: user.role == .ADMIN ? "Administrador" : "Usuario")
                    }
                }

                Section("WhatsApp") {
                    NavigationLink("Conectar a WhatsApp") { InstanceListView() }
                    NavigationLink("Respuestas automáticas") { AutoRepliesView() }
                }

                Section("Envíos") {
                    if session.upcoming.contains(where: { $0.status == .ACTIVE }) {
                        Button {
                            Task {
                                _ = try? await APIClient.shared.pauseAll(true)
                                await session.refreshMessages()
                            }
                        } label: {
                            Label("Pausar todos los envíos", systemImage: "pause.circle")
                        }
                    } else if session.upcoming.contains(where: { $0.status == .PAUSED }) {
                        Button {
                            Task {
                                _ = try? await APIClient.shared.pauseAll(false)
                                await session.refreshMessages()
                            }
                        } label: {
                            Label("Reanudar todos los envíos", systemImage: "play.circle")
                        }
                    } else {
                        Text("Sin mensajes pendientes.").foregroundStyle(.secondary)
                    }
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
    @State private var resetUser: User?
    @State private var newPassword = ""
    @State private var deleteUser: User?

    var body: some View {
        Form {
            usersSection
            invitesSection
        }
        .formStyle(.grouped)
        .navigationTitle("Usuarios")
        .task { await load() }
        .alert("Nueva contraseña para \(resetUser?.name ?? "")", isPresented: .init(
            get: { resetUser != nil }, set: { if !$0 { resetUser = nil } }
        )) {
            SecureField("Mínimo 8 caracteres", text: $newPassword)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") {
                if let u = resetUser, newPassword.count >= 8 {
                    Task { await change(u, password: newPassword) }
                }
            }
        } message: {
            Text("Se cerrarán sus sesiones activas.")
        }
        .confirmationDialog(
            "Se elimina el usuario, sus instancias de WhatsApp y todos sus mensajes. Irreversible.",
            isPresented: .init(get: { deleteUser != nil }, set: { if !$0 { deleteUser = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar \(deleteUser?.name ?? "")", role: .destructive) {
                if let u = deleteUser {
                    Task {
                        do {
                            _ = try await APIClient.shared.deleteUser(id: u.id)
                            await load()
                        } catch { session.report(error) }
                    }
                }
            }
        }
    }

    private var usersSection: some View {
        Section("Usuarios") {
            ForEach(users) { u in row(u) }
        }
    }

    private func row(_ u: User) -> AdminUserRow {
        AdminUserRow(
            user: u,
            isSelf: u.id == session.user?.id,
            onToggleRole: {
                let newRole: Role = u.role == .ADMIN ? .USER : .ADMIN
                Task { await change(u, role: newRole) }
            },
            onResetPassword: {
                resetUser = u
                newPassword = ""
            },
            onDelete: { deleteUser = u }
        )
    }

    private var invitesSection: some View {
        Section {
            Button("Crear código de invitación") {
                Task { invite = try? await APIClient.shared.createInvite() }
            }
            if let invite {
                LabeledContent("Código") {
                    Text(invite.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("Expira", value: invite.expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Invitaciones")
        } footer: {
            Text("Los usuarios nuevos se registran desde la app con este código (expira en 7 días).")
        }
    }

    private func load() async {
        users = (try? await APIClient.shared.adminUsers().items) ?? []
    }

    private func change(_ u: User, role: Role? = nil, password: String? = nil) async {
        do {
            _ = try await APIClient.shared.patchUser(id: u.id, role: role, password: password)
            await load()
        } catch { session.report(error) }
    }
}

struct AdminUserRow: View {
    let user: User
    let isSelf: Bool
    let onToggleRole: () -> Void
    let onResetPassword: () -> Void
    let onDelete: () -> Void

    private var badgeColor: Color {
        user.role == .ADMIN ? Theme.accent.opacity(0.2) : Color.gray.opacity(0.15)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                Text(user.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(user.role == .ADMIN ? "Admin" : "Usuario")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeColor, in: Capsule())
            if !isSelf {
                Menu {
                    Button(user.role == .ADMIN ? "Quitar rol admin" : "Hacer admin", action: onToggleRole)
                    Button("Resetear contraseña", action: onResetPassword)
                    Divider()
                    Button("Eliminar usuario", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}
