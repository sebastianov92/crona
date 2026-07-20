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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
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
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
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
        case history = "Historial"
        case settings = "Ajustes"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .scheduled: return "clock"
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
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
    }
}
#endif
