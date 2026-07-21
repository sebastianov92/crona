import Foundation
import Observation

/// Fuente de verdad = servidor (SPEC §9.5). Cache en memoria, sin DB local en v1.
@Observable @MainActor
final class SessionStore {
    enum Phase { case loading, needsServer, needsLogin, ready }

    var phase: Phase = .loading   // splash hasta saber si hay sesión válida (evita flash del login)
    var serverURL: URL?
    var user: User?
    var instances: [Instance] = []
    var activeInstanceId: String?
    var upcoming: [ScheduledMessage] = [] {
        didSet { WidgetBridge.publish(upcoming: upcoming) }
    }
    var history: [HistoryItem] = []
    var lastQR: (instanceId: String, qrBase64: String)?
    var toastError: String?
    var serverError: String?   // error de conexión mostrado en ServerSetupView

    private var accessToken: String?
    private let ws = WebSocketClient()

    var activeInstance: Instance? {
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
            serverError = "No se pudo conectar al servidor. Revisa la dirección o que esté encendido."
            phase = .needsServer
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
    }

    func refreshInstances() async {
        do {
            instances = try await APIClient.shared.instances().items
            if activeInstanceId == nil { activeInstanceId = instances.first?.id }
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
            NotificationCenter.default.post(name: .catchappMessageUpdated, object: msg)
        case .logUpdated(let log):
            NotificationCenter.default.post(name: .catchappLogUpdated, object: log)
            Task { await refreshHistory() }
        case .instanceUpdated(let inst):
            if let i = instances.firstIndex(where: { $0.id == inst.id }) { instances[i] = inst }
            else { instances.append(inst) }
            NotificationCenter.default.post(name: .catchappInstanceUpdated, object: inst)
        case .qrUpdated(let instanceId, let qrBase64):
            lastQR = (instanceId, qrBase64)
        }
    }
}

extension Notification.Name {
    static let catchappMessageUpdated = Notification.Name("catchapp.message.updated")
    static let catchappLogUpdated = Notification.Name("catchapp.log.updated")
    static let catchappInstanceUpdated = Notification.Name("catchapp.instance.updated")
}
