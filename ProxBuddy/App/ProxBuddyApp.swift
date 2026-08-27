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
        // iOS does not export LANG; CPython uses it during locale/codec setup.
        if getenv("LANG") == nil {
            setenv("LANG", "en_US.UTF-8", 1)
        }

        // BeeWare install_python (Xcode build phase) copies stdlib into
        // <App>.app/python/lib/python3.11 and rewrites lib-dynload .so files
        // into Frameworks/*.framework + .fwork stubs. CPython bootstraps
        // encodings from PYTHONHOME *before* PYTHONPATH is applied, so this
        // layout has to match getpath's {home}/lib/python3.11 exactly.
        let resourcePath = Bundle.main.resourcePath ?? ""
        let pyHome = (resourcePath as NSString).appendingPathComponent("python")
        let pyStdLib = (pyHome as NSString).appendingPathComponent("lib/python3.11")
        let dynLoad = (pyStdLib as NSString).appendingPathComponent("lib-dynload")
        let encodingsInit = (pyStdLib as NSString).appendingPathComponent("encodings/__init__.py")

        if !FileManager.default.fileExists(atPath: encodingsInit) {
            NSLog("[ProxBuddy] Python stdlib missing at \(pyStdLib). The 'Install Python stdlib' build phase did not run — regenerate the Xcode project with xcodegen and rebuild.")
        }

        setenv("PYTHONHOME", pyHome, 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)

        var paths = [pyStdLib, dynLoad]
        if let pyscripts = Bundle.main.url(forResource: "pyscripts", withExtension: nil) {
            paths.append(pyscripts.path)
        }
        setenv("PYTHONPATH", paths.joined(separator: ":"), 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceManager)
                .environmentObject(appNav)
                .environmentObject(scanHistory)
                .environmentObject(favorites)
                .onAppear {
                    KeyboardPrewarmer.prewarm()
                }
        }
    }
}
