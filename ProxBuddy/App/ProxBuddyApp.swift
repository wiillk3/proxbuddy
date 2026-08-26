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
        // BeeWare's Python.framework lives in Frameworks/
        // Python expects PYTHONHOME to point at the framework root
        // which contains Resources/lib/python3.13/
        if let fwPath = Bundle.main.privateFrameworksPath {
            let pythonFW = (fwPath as NSString).appendingPathComponent("Python.framework")
            setenv("PYTHONHOME", pythonFW, 1)
        } else {
            setenv("PYTHONHOME", Bundle.main.bundlePath, 1)
        }

        // PYTHONPATH: stdlib zip + bundle pyscripts
        var paths: [String] = []
        if let zip = Bundle.main.url(forResource: "python313", withExtension: "zip") {
            paths.append(zip.path)
        }
        if let pyscripts = Bundle.main.url(forResource: "pyscripts", withExtension: nil) {
            paths.append(pyscripts.path)
        }
        if !paths.isEmpty {
            setenv("PYTHONPATH", paths.joined(separator: ":"), 1)
        }

        // Prevent .pyc writes into read-only bundle
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
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
