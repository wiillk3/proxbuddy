import SwiftUI

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var browserPath: [BrowserDestination] = []
    static let terminalTab = 0
}

@main
struct ProxBuddyApp: App {
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var appNav        = AppNavigation()
    @StateObject private var scanHistory   = ScanHistoryStore()
    @StateObject private var favorites     = FavoritesStore()

    init() {
        if let pyZip = Bundle.main.url(forResource: "python311", withExtension: "zip") {
            setenv("PYTHONHOME", Bundle.main.bundlePath, 1)
            setenv("PYTHONPATH", pyZip.path, 1)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceManager)
                .environmentObject(appNav)
                .environmentObject(scanHistory)
                .environmentObject(favorites)
        }
    }
}
