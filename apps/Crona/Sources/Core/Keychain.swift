import Security
import Foundation
import CryptoKit

/// Almacén de la sesión (serverURL y refreshToken; el accessToken vive solo en memoria).
///
/// - **iOS**: Keychain del sistema. Es sólido y no genera avisos.
/// - **macOS**: archivo cifrado en Application Support (solo lectura/escritura del dueño).
///   El Keychain de macOS liga cada ítem al binario que lo creó, y como los DMG se firman
///   ad-hoc (identidad distinta en cada versión) pedía la contraseña del llavero en CADA
///   actualización. El archivo va cifrado con AES-GCM usando una clave derivada del
///   hardware del equipo, así no queda en texto plano.
enum Keychain {
    private static let service = "com.sebastianov.crona"

    static func set(_ value: String, for key: String) {
        #if os(macOS)
        SessionFile.set(value, for: key)
        #else
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }

    static func get(_ key: String) -> String? {
        #if os(macOS)
        if let v = SessionFile.get(key) { return v }
        // migración desde el Keychain de versiones anteriores, sin mostrar diálogos:
        // si macOS fuese a pedir la contraseña, falla en silencio y se pide iniciar sesión
        if let legacy = legacyKeychainGet(key) {
            SessionFile.set(legacy, for: key)
            return legacy
        }
        return nil
        #else
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    static func delete(_ key: String) {
        #if os(macOS)
        SessionFile.delete(key)
        #else
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        #endif
    }

    #if os(macOS)
    private static func legacyKeychainGet(_ key: String) -> String? {
        SecKeychainSetUserInteractionAllowed(false) // nada de diálogos durante la migración
        defer { SecKeychainSetUserInteractionAllowed(true) }
        for svc in [service, "com.sebastian.crona"] { // el id anterior al rebranding
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
    #endif
}

#if os(macOS)
import IOKit

/// Sesión cifrada en ~/Library/Application Support/Crona/session (permisos 0600).
private enum SessionFile {
    private static let queue = DispatchQueue(label: "crona.sessionfile")

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crona", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("session")
    }

    /// Clave estable por equipo: UUID de la placa + sal fija. No cambia al actualizar la app.
    private static var key: SymmetricKey {
        let port = IOServiceMatching("IOPlatformExpertDevice")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, port)
        defer { if svc != 0 { IOObjectRelease(svc) } }
        let uuid = (IORegistryEntryCreateCFProperty(svc, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? "crona-fallback"
        let material = Data(("crona.session.v1|" + uuid).utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    private static func load() -> [String: String] {
        queue.sync {
            guard let blob = try? Data(contentsOf: url),
                  let box = try? AES.GCM.SealedBox(combined: blob),
                  let plain = try? AES.GCM.open(box, using: key),
                  let dict = try? JSONDecoder().decode([String: String].self, from: plain) else { return [:] }
            return dict
        }
    }

    private static func save(_ dict: [String: String]) {
        queue.sync {
            guard let plain = try? JSONEncoder().encode(dict),
                  let box = try? AES.GCM.seal(plain, using: key),
                  let blob = box.combined else { return }
            try? blob.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func set(_ value: String, for key: String) {
        var d = load(); d[key] = value; save(d)
    }

    static func get(_ key: String) -> String? { load()[key] }

    static func delete(_ key: String) {
        var d = load(); d.removeValue(forKey: key); save(d)
    }
}
#endif
