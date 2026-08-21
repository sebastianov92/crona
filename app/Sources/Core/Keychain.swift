import Security
import Foundation

/// Sesión (serverURL y refreshToken) en el Keychain del sistema, en iOS y macOS.
/// El accessToken vive solo en memoria (APIClient).
///
/// Nota macOS: el Keychain liga cada ítem al binario que lo creó y los DMG se firman
/// ad-hoc (identidad distinta en cada versión), así que tras actualizar pide una vez la
/// contraseña del llavero. Se acepta ese aviso a cambio de no sacar el token del Keychain:
/// pulsa "Siempre permitir" para no repetirlo dentro de la misma versión.
enum Keychain {
    private static let service = "com.sebastianov.crona"
    private static let legacyServices = ["com.sebastian.crona"] // id anterior al rebranding

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        for svc in [service] + legacyServices {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: svc, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    static func delete(_ key: String) {
        for svc in [service] + legacyServices {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: svc, kSecAttrAccount as String: key]
            SecItemDelete(q as CFDictionary)
        }
    }
}
