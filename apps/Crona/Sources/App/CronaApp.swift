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
                    #if os(macOS)
                    LocalNotifications.setup()
                    #endif
                }
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
            case .needsLogin: LoginView()
            case .ready: MainView()
            }
        }
        .onAppear { Appearance(rawValue: appearance)?.apply() }
        .onChange(of: appearance) { _, new in Appearance(rawValue: new)?.apply() }
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

struct MainView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        #if os(macOS)
        MacMainView()
        #else
        TabView {
            ScheduledListView()
                .tabItem { Label("Programados", systemImage: "clock") }
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            HistoryView()
                .tabItem { Label("Historial", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
        }
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

    @State private var section: Section = .scheduled

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section {
            case .scheduled: ScheduledListView()
            case .chats: ChatsView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
    }
}
#endif
