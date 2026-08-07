import Foundation

/// Borrador local del compositor: guarda destinatarios, el texto de las partes y la fecha, para no
/// perder lo escrito si se cierra sin enviar. El media NO se guarda (se re-adjunta al reabrir).
struct ComposeDraft: Codable {
    var instanceId: String?
    var recipients: [Recipient]
    var texts: [String]
    var date: Date
    var savedAt: Date

    /// ¿Tiene algo que valga la pena recuperar?
    var isMeaningful: Bool {
        !recipients.isEmpty || texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Persistencia del borrador en UserDefaults (solo el compositor de mensajes nuevos).
enum DraftStore {
    private static let key = "composeDraft.v1"

    static func save(_ draft: ComposeDraft) {
        guard draft.isMeaningful else { clear(); return }
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> ComposeDraft? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let draft = try? JSONDecoder().decode(ComposeDraft.self, from: data),
              draft.isMeaningful else { return nil }
        return draft
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
