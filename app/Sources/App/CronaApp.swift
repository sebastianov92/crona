import SwiftUI

@main
struct CronaApp: App {
    @State private var session = SessionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Theme.accent)
                .task {
                    await session.bootstrap()
                    LocalNotifications.setup()
                    #if os(macOS)
                    await Updater.shared.checkAtLaunch()
                    #endif
                }
                #if os(macOS)
                .sheet(item: Binding(
                    get: { Updater.shared.pending },
                    set: { Updater.shared.pending = $0 }
                )) { rel in
                    UpdateSheet(release: rel)
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, session.phase == .ready {
                        Task { await session.refreshAll() }   // re-sync al volver a primer plano (§9.5)
                    }
                }
        }
        #if os(macOS)
        MenuBarExtra("Crona", systemImage: "paperplane.circle") {
            MenuBarView()
                .environment(session)
        }
        #endif
    }
}

// Apariencia elegida en Ajustes: "system" | "light" | "dark"
enum Appearance: String, CaseIterable {
    case system, light, dark

    // preferredColorScheme(nil) NO restaura "sistema" tras forzar un modo — usar APIs nativas
    func apply() {
        #if os(macOS)
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #else
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
    }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        Group {
            switch session.phase {
            case .loading: SplashView()
            case .needsServer: ServerSetupView()
            case .connectionError: ConnectionErrorView()
            case .needsLogin: LoginView()
            case .ready: MainView()
            }
        }
        .onAppear { Appearance(rawValue: appearance)?.apply() }
        .onChange(of: appearance) { _, new in Appearance(rawValue: new)?.apply() }
        .onOpenURL { session.handleDeepLink($0) }   // crona://setup?server=…&invite=…
        .alert("Error", isPresented: .init(
            get: { session.toastError != nil },
            set: { if !$0 { session.toastError = nil } }
        )) {
            Button("OK") { session.toastError = nil }
        } message: {
            Text(session.toastError ?? "")
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("CronaLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Servidor no alcanzable pero con sesión guardada: reintentar sin perder el login.
struct ConnectionErrorView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("CronaLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("No se pudo conectar al servidor")
                .font(.headline)
            Text(session.serverError ?? "Revisa tu conexión e inténtalo de nuevo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task {
                    session.phase = .loading   // muestra el splash mientras reintenta
                    await session.bootstrap()
                }
            } label: {
                Text("Reintentar").frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)

            Button("Cambiar servidor") {
                Keychain.delete("serverURL")
                session.phase = .needsServer
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

struct MainView: View {
    @Environment(SessionStore.self) private var session
    @State private var showInstances = false

    var body: some View {
        #if os(macOS)
        MacMainView()
        #else
        // Banner de desconexión a nivel de app: se ve en cualquier pestaña, no solo en Programados.
        VStack(spacing: 0) {
            if session.hasDisconnectedInstance {
                Button { showInstances = true } label: { DisconnectedBanner() }
                    .buttonStyle(.plain)
            }
            TabView {
                ScheduledListView()
                    .tabItem { Label("Programados", systemImage: "clock") }
                ChatsView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .badge(session.chatsUnread)
                HistoryView()
                    .tabItem { Label("Historial", systemImage: "clock.arrow.circlepath") }
                SettingsView()
                    .tabItem { Label("Ajustes", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showInstances) { InstancesSheet() }
        #endif
    }
}

/// Lista de instancias en hoja (para el banner de desconexión desde el shell).
struct InstancesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            InstanceListView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

#if os(macOS)
struct MacMainView: View {
    enum Section: String, CaseIterable, Identifiable {
        case scheduled = "Programados"
        case chats = "Chats"
        case history = "Historial"
        case settings = "Ajustes"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .scheduled: return "clock"
            case .chats: return "bubble.left.and.bubble.right"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(SessionStore.self) private var session
    @State private var section: Section = .scheduled
    @State private var showCompose = false
    @State private var showInstances = false
    @AppStorage("sidebarCollapsed") private var collapsed = false

    private var sidebarWidth: CGFloat { collapsed ? 64 : 200 }

    var body: some View {
        // Barra propia en vez de NavigationSplitView: al colapsar queremos que queden los
        // iconos, no que la barra desaparezca por completo.
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                // Banner de desconexión global (cualquier sección).
                if session.hasDisconnectedInstance {
                    Button { showInstances = true } label: { DisconnectedBanner() }
                        .buttonStyle(.plain)
                }
                Group {
                    switch section {
                    case .scheduled: ScheduledListView()
                    case .chats: ChatsView()
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // "Nuevo mensaje" de la menu bar funciona esté donde esté (antes solo en Programados).
        .sheet(isPresented: $showCompose) { ComposeView() }
        .sheet(isPresented: $showInstances) { InstancesSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .cronaNewMessage)) { _ in showCompose = true }
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            // expandida: logo completo · colapsada: isotipo
            // Los SVG traen el arte dentro de un lienzo 1920×1080 casi vacío (el logo ocupa
            // ~33% del alto), así que hay que agrandar la imagen y recortar el aire sobrante.
            Group {
                if collapsed {
                    Image("CronaIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 68, height: 38)   // lienzo escalado
                        .frame(width: 48, height: 34)   // ventana visible
                        .clipped()
                } else {
                    // el arte ocupa solo el 33% del alto del lienzo: se escala y se recorta el
                    // aire, dejando margen suficiente para que no se corte por arriba
                    Image("CronaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 119, height: 67)   // lienzo escalado → arte ≈ 22pt de alto
                        .frame(width: 184, height: 32)   // ventana visible (5pt de aire arriba y abajo)
                        .clipped()
                }
            }
            .frame(height: 44)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ForEach(Section.allCases) { s in
                Button {
                    section = s
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.icon)
                            .font(.system(size: 15))
                            .frame(width: 22)
                            // colapsada: punto rojo sobre el icono de Chats
                            .overlay(alignment: .topTrailing) {
                                if collapsed, s == .chats, session.chatsUnread > 0 {
                                    Circle().fill(.red).frame(width: 8, height: 8).offset(x: 4, y: -2)
                                }
                            }
                        if !collapsed {
                            Text(s.rawValue).font(.subheadline)
                            Spacer(minLength: 0)
                            if s == .chats, session.chatsUnread > 0 {
                                Text("\(session.chatsUnread)")
                                    .font(.caption2.bold()).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.red, in: Capsule())
                            }
                        }
                    }
                    .foregroundStyle(section == s ? Theme.accent : .primary)
                    .padding(.horizontal, collapsed ? 0 : 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(section == s ? Theme.accent.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(s.rawValue) // tooltip: imprescindible cuando solo se ve el icono
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expandir barra lateral" : "Colapsar barra lateral")
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .frame(width: sidebarWidth)
        .background(.ultraThinMaterial)
    }
}
#endif
