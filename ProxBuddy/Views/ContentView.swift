import SwiftUI

struct ContentView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var appNav:        AppNavigation
    @EnvironmentObject var scanHistory:   ScanHistoryStore
    @EnvironmentObject var favorites:     FavoritesStore

    @State private var launchError: String?

    var body: some View {
        Group {
            if let session = deviceManager.activeSession {
                sessionContent(session)
            } else {
                ProgressView("Initialising…")
            }
        }
        .task {
            if deviceManager.sessions.isEmpty {
                deviceManager.addSession(label: "PM5 1")
            }
            if let s = deviceManager.activeSession { await s.boot(scanHistory: scanHistory) }
        }
        .alert("Launch Error", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    // MARK: - Per-session content

    /// Injects the active session's engine / transport into the environment so all
    /// existing child views keep working unchanged.
    @ViewBuilder
    private func sessionContent(_ session: PM3Session) -> some View {
        #if targetEnvironment(simulator)
        mainTabs
            .environmentObject(session.engine)
            .environmentObject(session.runner)
        #else
        mainTabs
            .environmentObject(session.engine)
            .environmentObject(session.runner)
            .environmentObject(session.transport)
            .environmentObject(session.bleTransport)
        #endif
    }

    // MARK: - Tab bar

    private var mainTabs: some View {
        TabView(selection: $appNav.selectedTab) {
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(AppNavigation.terminalTab)

            CommandBrowserView()
                .tabItem { Label("Commands", systemImage: "rectangle.grid.2x2") }
                .tag(1)

            DumpManagerView()
                .tabItem { Label("Files", systemImage: "folder.fill") }
                .tag(2)

            ScanHistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
                .tag(3)

            DevicesView()
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(4)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(5)
        }
        .tint(.hackerGreen)
        .preferredColorScheme(.dark)
    }

    // MARK: - Terminal tab (iPad split / iPhone single)

    @ViewBuilder
    private var terminalTab: some View {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        if isIPad && deviceManager.sessions.count >= 2 {
            iPadSplitTerminal
        } else {
            TerminalView()
        }
    }

    /// Side-by-side terminals on iPad — each pane gets its own session injected.
    private var iPadSplitTerminal: some View {
        HStack(spacing: 0) {
            ForEach(Array(deviceManager.sessions.prefix(2).enumerated()), id: \.element.id) { idx, session in
                sessionPane(session)
                if idx == 0 {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPane(_ session: PM3Session) -> some View {
        #if targetEnvironment(simulator)
        TerminalView()
            .environmentObject(session.engine)
            .environmentObject(session.runner)
            .environmentObject(appNav)
        #else
        TerminalView()
            .environmentObject(session.engine)
            .environmentObject(session.runner)
            .environmentObject(session.transport)
            .environmentObject(session.bleTransport)
            .environmentObject(appNav)
        #endif
    }
}
