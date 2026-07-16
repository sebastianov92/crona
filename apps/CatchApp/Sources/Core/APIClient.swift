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

    private func refreshSession() async throws {
        guard let rt = Keychain.get("refreshToken") else { throw APIError.http(401) }
        struct Body: Encodable { let refreshToken: String }
        struct Resp: Decodable { let accessToken: String; let refreshToken: String }
        let r: Resp = try await request("POST", "/auth/refresh", body: Body(refreshToken: rt), retryOn401: false)
        Keychain.set(r.refreshToken, for: "refreshToken")
        accessToken = r.accessToken
    }

    // MARK: - Subida multipart (POST /media)

    func uploadMedia(data: Data, fileName: String, mimeType: String) async throws -> MediaUpload {
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
        guard (200..<300).contains(status) else {
            if let env = try? Self.decoder.decode(ErrorEnvelope.self, from: respData) {
                throw APIError.server(code: env.error.code, message: env.error.message)
            }
            throw APIError.http(status)
        }
        return try Self.decoder.decode(MediaUpload.self, from: respData)
    }

    /// Descarga autenticada de un media (preview).
    func mediaData(id: String) async throws -> Data {
        guard let baseURL else { throw APIError.notConfigured }
        var req = URLRequest(url: baseURL.appending(path: "/media/\(id)"))
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (200..<300).contains((resp as! HTTPURLResponse).statusCode) else { throw APIError.http((resp as! HTTPURLResponse).statusCode) }
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
                 notifyOnSent: Bool? = nil, password: String? = nil) async throws -> User {
        struct B: Encodable {
            var name: String?
            var ntfyTopic: String??
            var ntfyToken: String??
            var notifyOnSent: Bool?
            var password: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                if let name { try c.encode(name, forKey: .name) }
                if let ntfyTopic { try c.encode(ntfyTopic, forKey: .ntfyTopic) }
                if let ntfyToken { try c.encode(ntfyToken, forKey: .ntfyToken) }
                if let notifyOnSent { try c.encode(notifyOnSent, forKey: .notifyOnSent) }
                if let password { try c.encode(password, forKey: .password) }
            }
            enum K: String, CodingKey { case name, ntfyTopic, ntfyToken, notifyOnSent, password }
        }
        return try await request("PATCH", "/me", body: B(name: name, ntfyTopic: ntfyTopic, ntfyToken: ntfyToken, notifyOnSent: notifyOnSent, password: password))
    }

    // Admin
    func adminSettings() async throws -> AdminSettings { try await request("GET", "/admin/settings") }
    func putAdminSettings(evolutionBaseUrl: String, evolutionGlobalApiKey: String?, ntfyBaseUrl: String) async throws -> AdminSettings {
        struct B: Encodable { let evolutionBaseUrl: String; let evolutionGlobalApiKey: String?; let ntfyBaseUrl: String }
        return try await request("PUT", "/admin/settings", body: B(evolutionBaseUrl: evolutionBaseUrl, evolutionGlobalApiKey: evolutionGlobalApiKey, ntfyBaseUrl: ntfyBaseUrl))
    }
    func testAdminSettings() async throws -> SettingsTestResult { try await request("POST", "/admin/settings/test") }
    func adminUsers() async throws -> Paginated<User> { try await request("GET", "/admin/users") }
    func createInvite() async throws -> InviteResponse { try await request("POST", "/admin/invites") }

    // Instancias
    func instances() async throws -> Paginated<Instance> { try await request("GET", "/instances") }
    func createInstance(name: String) async throws -> CreateInstanceResponse {
        struct B: Encodable { let name: String }
        return try await request("POST", "/instances", body: B(name: name))
    }
    func instanceQR(id: String) async throws -> QRResponse { try await request("GET", "/instances/\(id)/qr") }
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
    func cancelMessage(id: String) async throws -> ScheduledMessage { try await request("POST", "/messages/\(id)/cancel") }
    func duplicateMessage(id: String) async throws -> ScheduledMessage { try await request("POST", "/messages/\(id)/duplicate") }
    func deleteMessage(id: String) async throws -> OkResponse { try await request("DELETE", "/messages/\(id)") }
}
