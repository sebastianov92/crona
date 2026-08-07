import Foundation
import Observation

/// Fuente de verdad = servidor (SPEC §9.5). Cache en memoria, sin DB local en v1.
@Observable @MainActor
final class SessionStore {
    enum Phase { case loading, needsServer, connectionError, needsLogin, ready }

    var phase: Phase = .loading   // splash hasta saber si hay sesión válida (evita flash del login)
    var serverURL: URL?
    var user: User?
    var instances: [Instance] = []
    var activeInstanceId: String?
    var upcoming: [ScheduledMessage] = [] {
        didSet {
            WidgetBridge.publish(upcoming: upcoming)
            LocalNotifications.reschedule(upcoming: upcoming)
        }
    }
    var history: [HistoryItem] = []
    var chatsUnread = 0   // total de no leídos → badge de la pestaña Chats
    // Cache de destinatarios por "instanceId|kind": abre el picker al instante y refresca en 2º plano
    // (antes re-descargaba TODOS los contactos —varias páginas— cada vez que se abría).
    var recipientCache: [String: [Recipient]] = [:]
    var lastQR: (instanceId: String, qrBase64: String)?
    var toastError: String?
    var serverError: String?   // error de conexión mostrado en ServerSetupView
    // Prefill que llega por deep-link crona://setup?server=…&invite=…
    var pendingSetupServer: String?
    var pendingInvite: String?

    private var accessToken: String?
    private let ws = WebSocketClient()

    var activeInstance: Instance? {
        // prioridad: la elegida en esta sesión → la primera de la lista (orden del usuario;
        // el server ya la devuelve ordenada y la primera es la principal)
        instances.first { $0.id == activeInstanceId } ?? instances.first
    }
    var isAdmin: Bool { user?.role == .ADMIN }
    var hasDisconnectedInstance: Bool {
        instances.contains { $0.status == .DISCONNECTED }
    }

    // MARK: - Arranque

    func bootstrap() async {
        guard let urlString = Keychain.get("serverURL"), let url = URL(string: urlString) else {
            phase = .needsServer; return
        }
        serverURL = url
        await APIClient.shared.configure(baseURL: url)
        // verificar servidor ANTES de mandar al login: si no responde, volver a la pantalla de servidor
        do {
            _ = try await APIClient.shared.health()
            serverError = nil
        } catch {
            serverError = "No se pudo conectar al servidor. Revisa tu conexión o que esté encendido."
            // Un corte transitorio no debe expulsar a un usuario ya logueado al editor de URL:
            // si hay sesión, mostrar pantalla de reintento; si es alta nueva, pedir el servidor.
            phase = Keychain.get("refreshToken") != nil ? .connectionError : .needsServer
            return
        }
        guard Keychain.get("refreshToken") != nil else { phase = .needsLogin; return }
        do {
            // fuerza refresh: el access de una sesión anterior ya no vive en memoria
            user = try await APIClient.shared.me()
            phase = .ready
            await afterLogin()
        } catch {
            phase = .needsLogin
        }
    }

    /// Deep-link de invitación: crona://setup?server=…&invite=…
    /// Guarda el prefill; si aún no hay servidor configurado, manda a la pantalla de servidor.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "crona", url.host == "setup" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let server = items.first { $0.name == "server" }?.value
        let invite = items.first { $0.name == "invite" }?.value
        if let server, !server.isEmpty { pendingSetupServer = server }
        if let invite, !invite.isEmpty { pendingInvite = invite }
        // si no hay sesión aún, llevar al usuario a conectar el servidor con lo prellenado
        if phase == .needsLogin, pendingSetupServer == nil {
            // ya hay servidor; solo falta registrarse con el código → LoginView abre Registro
        } else if phase != .ready {
            phase = .needsServer
        }
    }

    func setServer(url: URL) async throws {
        await APIClient.shared.configure(baseURL: url)
        _ = try await APIClient.shared.health()
        Keychain.set(url.absoluteString, for: "serverURL")
        serverURL = url
        phase = .needsLogin
    }

    // MARK: - Sesión

    func login(email: String, password: String) async throws {
        let r = try await APIClient.shared.login(email: email, password: password)
        try await startSession(r)
    }

    func register(email: String, password: String, name: String, inviteCode: String?) async throws {
        let r = try await APIClient.shared.register(email: email, password: password, name: name, inviteCode: inviteCode?.isEmpty == true ? nil : inviteCode)
        try await startSession(r)
    }

    private func startSession(_ r: AuthResponse) async throws {
        Keychain.set(r.refreshToken, for: "refreshToken")
        await APIClient.shared.setAccessToken(r.accessToken)
        accessToken = r.accessToken
        user = r.user
        phase = .ready
        await afterLogin()
    }

    func logout() async {
        if let rt = Keychain.get("refreshToken") {
            _ = try? await APIClient.shared.logout(refreshToken: rt)
        }
        Keychain.delete("refreshToken")
        await APIClient.shared.setAccessToken(nil)
        accessToken = nil
        ws.disconnect()
        user = nil; instances = []; upcoming = []; history = []
        phase = .needsLogin
    }

    private func afterLogin() async {
        connectWS()
        await refreshAll()
    }

    // MARK: - Datos

    func refreshAll() async {
        await refreshInstances()
        await refreshMessages()
        Task { await refreshChatsUnread() }
        Task { await prefetchContacts() }   // calienta el cache del picker (primer abrir instantáneo)
    }

    /// Suma los no leídos de todos los chats para el badge de la pestaña.
    func refreshChatsUnread() async {
        if let items = try? await APIClient.shared.chats().items {
            chatsUnread = items.reduce(0) { $0 + ($1.unread ?? 0) }
        }
    }

    /// Precarga los contactos de la instancia activa en segundo plano para que el selector
    /// abra al instante la primera vez. El refresco al abrir el picker mantiene la lista al día.
    func prefetchContacts() async {
        guard let iid = activeInstance?.id else { return }
        let key = "\(iid)|\(RecipientKind.CONTACT)"
        guard recipientCache[key] == nil else { return }
        if let all = try? await APIClient.shared.allRecipients(instanceId: iid, kind: .CONTACT, search: "") {
            recipientCache[key] = all
        }
    }

    func refreshInstances() async {
        do {
            instances = try await APIClient.shared.instances().items
            // activeInstanceId queda nil hasta que el usuario elija: así `activeInstance`
            // cae en la instancia principal configurada (defaultInstanceId)
        } catch { report(error) }
    }

    func refreshMessages() async {
        do { upcoming = try await APIClient.shared.upcomingMessages().items } catch { report(error) }
    }

    func refreshHistory() async {
        do { history = try await APIClient.shared.history().items } catch { report(error) }
    }

    func report(_ error: Error) {
        // tareas canceladas (cambio de vista, .task re-lanzada al abrir la app) no son errores reales
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        toastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - WebSocket (mejora, no requisito de consistencia)

    private func connectWS() {
        guard let serverURL else { return }
        ws.onEvent = { [weak self] event in self?.handle(event) }
        ws.connect(baseURL: serverURL) {
            await APIClient.shared.currentAccessToken()
        }
    }

    private func handle(_ event: WSEvent) {
        switch event {
        case .messageUpdated(let msg):
            if msg.status == .ACTIVE || msg.status == .PAUSED {
                if let i = upcoming.firstIndex(where: { $0.id == msg.id }) { upcoming[i] = msg }
                else { upcoming.append(msg); upcoming.sort { $0.nextRunAt < $1.nextRunAt } }
            } else {
                upcoming.removeAll { $0.id == msg.id }
            }
            NotificationCenter.default.post(name: .cronaMessageUpdated, object: msg)
        case .logUpdated(let log):
            NotificationCenter.default.post(name: .cronaLogUpdated, object: log)
            Task { await refreshHistory() }
        case .instanceUpdated(let inst):
            if let i = instances.firstIndex(where: { $0.id == inst.id }) { instances[i] = inst }
            else { instances.append(inst) }
            NotificationCenter.default.post(name: .cronaInstanceUpdated, object: inst)
        case .qrUpdated(let instanceId, let qrBase64):
            lastQR = (instanceId, qrBase64)
        case .chatIncoming(let instanceId, let jid):
            NotificationCenter.default.post(name: .cronaChatIncoming, object: nil,
                                            userInfo: ["instanceId": instanceId, "jid": jid])
            Task { await refreshChatsUnread() }   // actualiza el badge al llegar un entrante
        }
    }
}

extension Notification.Name {
    static let cronaMessageUpdated = Notification.Name("crona.message.updated")
    static let cronaLogUpdated = Notification.Name("crona.log.updated")
    static let cronaInstanceUpdated = Notification.Name("crona.instance.updated")
    static let cronaChatIncoming = Notification.Name("crona.chat.incoming")
}
