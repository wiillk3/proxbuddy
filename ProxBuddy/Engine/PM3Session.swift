import Foundation

enum TransportMode: Hashable, Identifiable {
    case ble
    case wifiDirect(host: String, port: UInt16)
    case bridge

    var id: String {
        switch self {
        case .ble: return "ble"
        case .wifiDirect(let h, let p): return "wifi-\(h):\(p)"
        case .bridge: return "bridge"
        }
    }
}

/// One connected Proxmark — bundles runner, engine, and active transport together.
@MainActor
final class PM3Session: ObservableObject, Identifiable {
    let id = UUID()
    @Published var label: String
    @Published var selectedTransportMode: TransportMode = .ble

    let runner = BinaryRunner()
    let engine = TerminalEngine()

    #if !targetEnvironment(simulator)
    let bleTransport = BLETransport()
    let tcpTransport = TcpTransport()
    var transport: TcpTransport { tcpTransport }
    #endif

    init(label: String) { self.label = label }

    // MARK: - Status

    var isRunning: Bool { runner.isRunning }

    #if !targetEnvironment(simulator)
    var statusMessage: String {
        switch selectedTransportMode {
        case .ble:
            if let name = bleTransport.connectedPeripheralName {
                return "BLE: \(name) (\(bleTransport.connectionState.rawValue))"
            }
            return "BLE: \(bleTransport.connectionState.rawValue)"
        case .wifiDirect, .bridge:
            return tcpTransport.statusMessage
        }
    }

    var batteryLevel: Int? {
        if case .ble = selectedTransportMode {
            return bleTransport.batteryLevel
        }
        return nil
    }

    var isTransportReady: Bool { true }
    #else
    var statusMessage: String { runner.isRunning ? "USB direct (sim)" : "Stopped" }
    var batteryLevel: Int? { nil }
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
        // Attach active transport relay to the port pair BinaryRunner created
        if runner.portMasterFD >= 0 {
            switch selectedTransportMode {
            case .ble:
                bleTransport.attach(portFD: runner.portMasterFD)
            case .wifiDirect(let host, let port):
                tcpTransport.connect(host: host, port: port)
                tcpTransport.attach(portFD: runner.portMasterFD)
            case .bridge:
                tcpTransport.startBrowsing()
                tcpTransport.attach(portFD: runner.portMasterFD)
            }
        }
        Task { await engine.connect(to: runner) }
        #endif
    }

    /// Terminate the running client (if any) then boot fresh.
    func restart(scanHistory: ScanHistoryStore) async {
        runner.terminate()
        await boot(scanHistory: scanHistory)
    }

    func terminate() {
        runner.terminate()
        #if !targetEnvironment(simulator)
        bleTransport.disconnect()
        tcpTransport.disconnect()
        #endif
    }
}
