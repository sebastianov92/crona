#if os(macOS)
import SwiftUI
import AppKit

/// Auto-actualizador de la app de Mac (sin dependencias, estilo Sparkle casero).
///
/// Fuente de verdad: el último release de GitHub (tag vX.Y.Z + asset Crona.dmg + notas).
/// - "Actualizar automáticamente" ON  → al abrir la app se descarga e instala sola.
/// - OFF → aparece un aviso con el changelog y 3 opciones: Actualizar / Recordármelo
///   más tarde (reaparece la próxima vez) / Saltar esta versión (no vuelve a avisar
///   hasta que salga otra).
///
/// La instalación monta el DMG, reemplaza /Aplicaciones/Crona.app, quita la cuarentena
/// (por eso la app de Mac va SIN App Sandbox) y relanza.
@Observable @MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Identifiable {
        let version: String
        let changelog: String
        let dmgURL: URL
        var id: String { version }
    }

    var pending: Release? // dispara la hoja de aviso
    var checking = false
    var installing = false
    var status: String? // resultado de "Buscar actualizaciones" (al día / error)

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var autoUpdateEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoUpdate")
    }

    // MARK: - Chequeos

    /// Al abrir la app: silencioso. Auto → instala; manual → aviso (salvo versión saltada).
    func checkAtLaunch() async {
        guard let rel = try? await fetchLatest() else { return }
        guard Self.isNewer(rel.version, than: Self.currentVersion) else { return }
        if Self.autoUpdateEnabled {
            await install(rel)
        } else if rel.version != UserDefaults.standard.string(forKey: "skippedVersion") {
            pending = rel
        }
    }

    /// Botón "Buscar actualizaciones": siempre responde algo, e ignora la versión saltada.
    func checkManually() async {
        checking = true
        status = nil
        defer { checking = false }
        do {
            let rel = try await fetchLatest()
            if Self.isNewer(rel.version, than: Self.currentVersion) {
                UserDefaults.standard.removeObject(forKey: "skippedVersion")
                pending = rel
            } else {
                status = "Estás al día (v\(Self.currentVersion))."
            }
        } catch {
            status = "No se pudo buscar actualizaciones. Revisa tu conexión."
        }
    }

    func remindLater() { pending = nil }

    func skip(_ rel: Release) {
        UserDefaults.standard.set(rel.version, forKey: "skippedVersion")
        pending = nil
    }

    // MARK: - Instalación

    func install(_ rel: Release) async {
        installing = true
        defer { installing = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: rel.dmgURL)
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Crona-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)

            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("crona-update-mount").path
            try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount])
            defer { try? run("/usr/bin/hdiutil", ["detach", mount, "-quiet", "-force"]) }

            let src = mount + "/Crona.app"
            let dest = Bundle.main.bundlePath // normalmente /Applications/Crona.app
            guard FileManager.default.fileExists(atPath: src) else { throw UpdateError.dmgSinApp }

            try run("/bin/rm", ["-rf", dest])
            try run("/usr/bin/ditto", [src, dest])
            // sin cuarentena el reemplazo ad-hoc abre igual que la app original
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest])

            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", dest]
            try open.run()
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
        } catch {
            status = "La actualización falló. Descarga Crona.dmg desde GitHub e instala manualmente."
            pending = nil
        }
    }

    // MARK: - GitHub

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/sebastianov92/crona/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.github }

        struct GHRelease: Decodable {
            let tag_name: String
            let body: String?
            let assets: [Asset]
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let dmg = gh.assets.first(where: { $0.name == "Crona.dmg" }),
              let url = URL(string: dmg.browser_download_url) else { throw UpdateError.dmgSinApp }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        let notes = (gh.body?.isEmpty == false ? gh.body! : "Sin notas para esta versión.")
        return Release(version: version, changelog: notes, dmgURL: url)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: Error { case github, dmgSinApp }

    @discardableResult
    private func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "crona.updater", code: Int(p.terminationStatus))
        }
        return p.terminationStatus
    }
}

/// Aviso de nueva versión: changelog scrolleable + Actualizar / Más tarde / Saltar.
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let release: Updater.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("CronaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nueva versión disponible").font(.headline)
                    Text("Crona v\(release.version) — tienes la v\(Updater.currentVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Novedades").font(.subheadline.bold())
            ScrollView {
                Text(release.changelog)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 220)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.2)))

            if Updater.shared.installing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Descargando e instalando… la app se reiniciará sola.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack {
                    Button("Saltar esta versión") { Updater.shared.skip(release) }
                    Spacer()
                    Button("Recordármelo más tarde") { Updater.shared.remindLater() }
                    Button("Actualizar") {
                        Task { await Updater.shared.install(release) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(Updater.shared.installing)
    }
}
#endif
