import Foundation

enum APIError: Error, LocalizedError {
    case notConfigured
    case http(Int)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "El servidor no está configurado."
        case .http(let status): return "Error de red (HTTP \(status))."
        case .server(_, let message): return message
        }
    }
}

actor APIClient {
    static let shared = APIClient()
    private(set) var baseURL: URL?
    private var accessToken: String?

    func configure(baseURL: URL) { self.baseURL = baseURL }
    func setAccessToken(_ t: String?) { accessToken = t }
    func currentAccessToken() -> String? { accessToken }

    static let decoder: JSONDecoder = {
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter();   noFrac.formatOptions = [.withInternetDateTime]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let dt = withFrac.date(from: s) ?? noFrac.date(from: s) { return dt }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Fecha inválida: \(s)"))
        }
        return d
    }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String,
        body: B? = nil as String?, query: [URLQueryItem] = [], retryOn401: Bool = true) async throws -> T {
        guard let baseURL else { throw APIError.notConfigured }
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try Self.encoder.encode(body)
                      req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        if status == 401, retryOn401 {
            try await refreshSession()
            return try await request(method, path, body: body, query: query, retryOn401: false)
        }
        guard (200..<300).contains(status) else {
            if let env = try? Self.decoder.decode(ErrorEnvelope.self, from: data) {
                throw APIError.server(code: env.error.code, message: env.error.message)
            }
            throw APIError.http(status)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // Single-flight: si varios requests reciben 401 a la vez, solo UNO rota el refresh token
    // (el backend revoca el usado — un segundo refresh concurrente mataría la sesión).
    private var refreshTask: Task<Void, Error>?

    private func refreshSession() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let task = Task {
            defer { self.refreshTask = nil }
            guard let rt = Keychain.get("refreshToken") else { throw APIError.http(401) }
            struct Body: Encodable { let refreshToken: String }
            struct Resp: Decodable { let accessToken: String; let refreshToken: String }
            let r: Resp = try await self.request("POST", "/auth/refresh", body: Body(refreshToken: rt), retryOn401: false)
            Keychain.set(r.refreshToken, for: "refreshToken")
            self.accessToken = r.accessToken
        }
        refreshTask = task
        try await task.value
    }

    // MARK: - Subida multipart (POST /media)

    func uploadMedia(data: Data, fileName: String, mimeType: String, retryOn401: Bool = true) async throws -> MediaUpload {
        guard let baseURL else { throw APIError.notConfigured }
        let boundary = "catchapp-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appending(path: "/media"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }

        var form = Data()
        form.append(Data("--\(boundary)\r\n".utf8))
        form.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        form.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        form.append(data)
        form.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (respData, resp) = try await URLSession.shared.upload(for: req, from: form)
        let status = (resp as! HTTPURLResponse).statusCode
        if status == 401, retryOn401 {
            try await refreshSession()
            return try await uploadMedia(data: data, fileName: fileName, mimeType: mimeType, retryOn401: false)
        }
        guard (200..<300).contains(status) else {
            if let env = try? Self.decoder.decode(ErrorEnvelope.self, from: respData) {
                throw APIError.server(code: env.error.code, message: env.error.message)
            }
            throw APIError.http(status)
        }
        return try Self.decoder.decode(MediaUpload.self, from: respData)
    }

    /// Descarga autenticada de un media (preview).
    func mediaData(id: String, retryOn401: Bool = true) async throws -> Data {
        guard let baseURL else { throw APIError.notConfigured }
        var req = URLRequest(url: baseURL.appending(path: "/media/\(id)"))
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        if status == 401, retryOn401 {
            try await refreshSession()
            return try await mediaData(id: id, retryOn401: false)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        return data
    }
}

struct ErrorEnvelope: Decodable { struct E: Decodable { let code: String; let message: String }; let error: E }

// MARK: - Endpoints tipados

extension APIClient {
    struct Empty: Encodable {}

    // Auth
    func register(email: String, password: String, name: String, inviteCode: String?) async throws -> AuthResponse {
        struct B: Encodable { let email: String; let password: String; let name: String; let inviteCode: String? }
        return try await request("POST", "/auth/register", body: B(email: email, password: password, name: name, inviteCode: inviteCode))
    }
    func login(email: String, password: String) async throws -> AuthResponse {
        struct B: Encodable { let email: String; let password: String }
        return try await request("POST", "/auth/login", body: B(email: email, password: password))
    }
    func logout(refreshToken: String) async throws -> OkResponse {
        struct B: Encodable { let refreshToken: String }
        return try await request("POST", "/auth/logout", body: B(refreshToken: refreshToken))
    }
    func health() async throws -> HealthResponse { try await request("GET", "/health") }

    // Perfil
    func me() async throws -> User { try await request("GET", "/me") }
    func patchMe(name: String? = nil, ntfyTopic: String?? = nil, ntfyToken: String?? = nil,
                 notifyOnSent: Bool? = nil, password: String? = nil,
                 chatListCount: Int? = nil, chatIncomingCount: Int? = nil,
                 quickHours: QuickHours? = nil) async throws -> User {
        struct B: Encodable {
            var name: String?
            var ntfyTopic: String??
            var ntfyToken: String??
            var notifyOnSent: Bool?
            var password: String?
            var chatListCount: Int?
            var chatIncomingCount: Int?
            var quickHours: QuickHours?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                if let name { try c.encode(name, forKey: .name) }
                if let ntfyTopic { try c.encode(ntfyTopic, forKey: .ntfyTopic) }
                if let ntfyToken { try c.encode(ntfyToken, forKey: .ntfyToken) }
                if let notifyOnSent { try c.encode(notifyOnSent, forKey: .notifyOnSent) }
                if let password { try c.encode(password, forKey: .password) }
                if let chatListCount { try c.encode(chatListCount, forKey: .chatListCount) }
                if let chatIncomingCount { try c.encode(chatIncomingCount, forKey: .chatIncomingCount) }
                if let quickHours { try c.encode(quickHours, forKey: .quickHours) }
            }
            enum K: String, CodingKey { case name, ntfyTopic, ntfyToken, notifyOnSent, password, chatListCount, chatIncomingCount, quickHours }
        }
        return try await request("PATCH", "/me", body: B(name: name, ntfyTopic: ntfyTopic, ntfyToken: ntfyToken, notifyOnSent: notifyOnSent, password: password, chatListCount: chatListCount, chatIncomingCount: chatIncomingCount, quickHours: quickHours))
    }

    // Chats
    func chats() async throws -> Paginated<ChatSummary> { try await request("GET", "/chats") }
    func chatMessages(instanceId: String, jid: String) async throws -> Paginated<ChatBubble> {
        try await request("GET", "/chats/messages", query: [
            .init(name: "instanceId", value: instanceId),
            .init(name: "jid", value: jid),
        ])
    }
    func hideChat(instanceId: String, jid: String) async throws -> OkResponse {
        try await request("DELETE", "/chats", query: [
            .init(name: "instanceId", value: instanceId),
            .init(name: "jid", value: jid),
        ])
    }

    // Listas
    func lists() async throws -> Paginated<ContactList> { try await request("GET", "/lists") }
    func createList(instanceId: String, name: String, members: [ContactListMember]) async throws -> ContactList {
        struct B: Encodable { let instanceId: String; let name: String; let members: [ContactListMember] }
        return try await request("POST", "/lists", body: B(instanceId: instanceId, name: name, members: members))
    }
    func deleteList(id: String) async throws -> OkResponse { try await request("DELETE", "/lists/\(id)") }

    // Admin
    func adminSettings() async throws -> AdminSettings { try await request("GET", "/admin/settings") }
    func putAdminSettings(evolutionBaseUrl: String, evolutionGlobalApiKey: String?, ntfyBaseUrl: String) async throws -> AdminSettings {
        struct B: Encodable { let evolutionBaseUrl: String; let evolutionGlobalApiKey: String?; let ntfyBaseUrl: String }
        return try await request("PUT", "/admin/settings", body: B(evolutionBaseUrl: evolutionBaseUrl, evolutionGlobalApiKey: evolutionGlobalApiKey, ntfyBaseUrl: ntfyBaseUrl))
    }
    func testAdminSettings() async throws -> SettingsTestResult { try await request("POST", "/admin/settings/test") }
    func adminUsers() async throws -> Paginated<User> { try await request("GET", "/admin/users") }
    func patchUser(id: String, role: Role? = nil, password: String? = nil, name: String? = nil) async throws -> User {
        struct B: Encodable { let role: Role?; let password: String?; let name: String? }
        return try await request("PATCH", "/admin/users/\(id)", body: B(role: role, password: password, name: name))
    }
    func deleteUser(id: String) async throws -> OkResponse { try await request("DELETE", "/admin/users/\(id)") }
    func createInvite() async throws -> InviteResponse { try await request("POST", "/admin/invites") }

    // Instancias
    func instances() async throws -> Paginated<Instance> { try await request("GET", "/instances") }
    func createInstance(name: String, phoneNumber: String? = nil) async throws -> CreateInstanceResponse {
        struct B: Encodable { let name: String; let phoneNumber: String? }
        return try await request("POST", "/instances", body: B(name: name, phoneNumber: phoneNumber))
    }
    func instanceQR(id: String, number: String? = nil) async throws -> QRResponse {
        var q: [URLQueryItem] = []
        if let number { q.append(.init(name: "number", value: number)) }
        return try await request("GET", "/instances/\(id)/qr", query: q)
    }
    func instanceStatus(id: String) async throws -> Instance { try await request("GET", "/instances/\(id)/status") }
    func syncInstance(id: String) async throws -> SyncResult { try await request("POST", "/instances/\(id)/sync") }
    func deleteInstance(id: String) async throws -> OkResponse { try await request("DELETE", "/instances/\(id)") }
    func recipients(instanceId: String, kind: RecipientKind?, search: String, cursor: String? = nil) async throws -> Paginated<Recipient> {
        var q: [URLQueryItem] = []
        if let kind { q.append(.init(name: "kind", value: kind.rawValue)) }
        if !search.isEmpty { q.append(.init(name: "search", value: search)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await request("GET", "/instances/\(instanceId)/recipients", query: q)
    }
    func renameRecipient(instanceId: String, recipientId: String, alias: String?) async throws -> Recipient {
        struct B: Encodable { let alias: String? }
        return try await request("PATCH", "/instances/\(instanceId)/recipients/\(recipientId)", body: B(alias: alias))
    }

    // Mensajes
    func upcomingMessages(cursor: String? = nil) async throws -> Paginated<ScheduledMessage> {
        var q: [URLQueryItem] = [.init(name: "filter", value: "upcoming")]
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await request("GET", "/messages", query: q)
    }
    func history(cursor: String? = nil) async throws -> Paginated<HistoryItem> {
        var q: [URLQueryItem] = [.init(name: "filter", value: "history")]
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return try await request("GET", "/messages", query: q)
    }
    func createMessage(_ body: CreateMessageBody) async throws -> ScheduledMessage {
        try await request("POST", "/messages", body: body)
    }
    func messageDetail(id: String) async throws -> MessageDetail { try await request("GET", "/messages/\(id)") }
    func patchMessage(id: String, _ body: PatchMessageBody) async throws -> ScheduledMessage {
        try await request("PATCH", "/messages/\(id)", body: body)
    }
    func sendNow(id: String) async throws -> ScheduledMessage { try await request("POST", "/messages/\(id)/send-now") }
    func pauseAll(_ paused: Bool) async throws -> OkResponse {
        struct B: Encodable { let paused: Bool }
        return try await request("POST", "/messages/pause-all", body: B(paused: paused))
    }

    // Respuestas automáticas
    func autoReplies() async throws -> Paginated<AutoReply> { try await request("GET", "/autoreplies") }
    func createAutoReply(_ body: AutoReplyBody) async throws -> AutoReply { try await request("POST", "/autoreplies", body: body) }
    func patchAutoReply(id: String, _ body: AutoReplyBody) async throws -> AutoReply { try await request("PATCH", "/autoreplies/\(id)", body: body) }
    func setAutoReplyEnabled(id: String, enabled: Bool) async throws -> AutoReply {
        struct B: Encodable { let enabled: Bool }
        return try await request("PATCH", "/autoreplies/\(id)", body: B(enabled: enabled))
    }
    func deleteAutoReply(id: String) async throws -> OkResponse { try await request("DELETE", "/autoreplies/\(id)") }
    func cancelMessage(id: String) async throws -> ScheduledMessage { try await request("POST", "/messages/\(id)/cancel") }
    func duplicateMessage(id: String) async throws -> ScheduledMessage { try await request("POST", "/messages/\(id)/duplicate") }
    func deleteMessage(id: String) async throws -> OkResponse { try await request("DELETE", "/messages/\(id)") }
    func deleteLog(id: String) async throws -> OkResponse { try await request("DELETE", "/messages/logs/\(id)") }
}
