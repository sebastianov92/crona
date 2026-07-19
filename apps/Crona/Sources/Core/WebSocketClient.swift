import Foundation

/// Evento del hub (§6): payload crudo re-decodificado según `type`.
enum WSEvent {
    case messageUpdated(ScheduledMessage)
    case logUpdated(MessageLog)
    case instanceUpdated(Instance)
    case qrUpdated(instanceId: String, qrBase64: String)
}

final class WebSocketClient: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var retry = 0
    private var closed = false
    private var baseURL: URL?
    private var tokenProvider: (() async -> String?)?

    var onEvent: (@MainActor (WSEvent) -> Void)?

    func connect(baseURL: URL, tokenProvider: @escaping () async -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        closed = false
        Task { await open() }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func open() async {
        guard let baseURL, let token = await tokenProvider?(), !closed else { return }
        var c = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https") ? "wss" : "ws"          // HTTP soportado (SPEC §2)
        c.queryItems = [.init(name: "token", value: token)]
        task = URLSession.shared.webSocketTask(with: c.url!)
        task?.resume()
        listen()
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let msg):
                self.retry = 0
                if case .string(let s) = msg, let ev = Self.decode(s) {
                    Task { @MainActor in self.onEvent?(ev) }
                }
                self.listen()
            case .failure:
                let delay = min(pow(2, Double(self.retry)), 30); self.retry += 1
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    Task { await self?.open() }   // re-lee token vigente
                }
            }
        }
    }

    private static func decode(_ s: String) -> WSEvent? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"],
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let d = APIClient.decoder
        switch type {
        case "message.updated": return (try? d.decode(ScheduledMessage.self, from: payloadData)).map(WSEvent.messageUpdated)
        case "log.updated": return (try? d.decode(MessageLog.self, from: payloadData)).map(WSEvent.logUpdated)
        case "instance.updated": return (try? d.decode(Instance.self, from: payloadData)).map(WSEvent.instanceUpdated)
        case "qr.updated":
            guard let p = payload as? [String: Any],
                  let id = p["instanceId"] as? String, let qr = p["qrBase64"] as? String else { return nil }
            return .qrUpdated(instanceId: id, qrBase64: qr)
        default: return nil
        }
    }
}
