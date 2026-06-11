import Foundation

/// One connected Proxmark3 — bundles runner, engine, and transport together.
@MainActor
final class PM3Session: ObservableObject, Identifiable {
    let id = UUID()
    @Published var label: String

    let runner = BinaryRunner()
    let engine = TerminalEngine()

    #if !targetEnvironment(simulator)
    let transport = TcpTransport()
    #endif

    init(label: String) { self.label = label }

    // MARK: - Status

    var isRunning: Bool { runner.isRunning }

    #if !targetEnvironment(simulator)
    var statusMessage: String { transport.statusMessage }
    var isTransportReady: Bool { true }   // port pair created internally; always launchable
    #else
    var statusMessage: String { runner.isRunning ? "USB direct (sim)" : "Stopped" }
    var isTransportReady: Bool { true }
    #endif

    // MARK: - Lifecycle

    func boot(scanHistory: ScanHistoryStore) async {
        engine.scanHistory = scanHistory
        runner.resetStream()

        #if targetEnvironment(simulator)
        guard let pm3  = SimulatorBoot.pm3BinaryPath() else { return }
        guard let port = SimulatorBoot.usbSerialPort()  else { return }
        do {
            try await runner.launch(binaryPath: pm3, portPath: port)
        } catch {
            engine.append(raw: "[!] boot: launch failed — \(error.localizedDescription)", isInput: false)
            return
        }
        Task { await engine.connect(to: runner) }

        #else
        let bundledURL = Bundle.main.url(forResource: "libpm3client", withExtension: "dylib", subdirectory: "Frameworks") 
            ?? Bundle.main.url(forResource: "libpm3client", withExtension: "dylib")
        let binaryInUse = bundledURL?.path ?? "none"
        engine.append(raw: "[=] boot: \(binaryInUse)", isInput: false)
        do {
            try await runner.launch()
        } catch {
            engine.append(raw: "[!] boot: launch failed — \(error.localizedDescription)", isInput: false)
            return
        }
        // Attach transport relay to the port pair BinaryRunner created
        if runner.portMasterFD >= 0 {
            transport.attach(portFD: runner.portMasterFD)
        }
        Task { await engine.connect(to: runner) }
        #endif
    }

    /// Terminate the running client (if any) then boot fresh.
    func restart(scanHistory: ScanHistoryStore) async {
        runner.terminate()
        await boot(scanHistory: scanHistory)
    }

    func terminate() { runner.terminate() }
}
