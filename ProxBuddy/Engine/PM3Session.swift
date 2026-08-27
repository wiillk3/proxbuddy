import Foundation
import Combine

enum TransportMode: Hashable, Identifiable {
    case ble
    case wifiDirect(host: String, port: UInt16)

    var id: String {
        switch self {
        case .ble: return "ble"
        case .wifiDirect(let h, let p): return "wifi-\(h):\(p)"
        }
    }
}

/// One connected Proxmark — bundles runner, engine, and active transport together.
@MainActor
final class PM3Session: ObservableObject, Identifiable {
    let id = UUID()
    @Published var label: String
    @Published var selectedTransportMode: TransportMode = .ble {
        didSet { refreshDerivedStatus() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Stopped"
    @Published private(set) var batteryLevel: Int? = nil
    @Published private(set) var isTransportReady = false
    private var gaugeSoC: Int?

    let runner = BinaryRunner()
    let engine = TerminalEngine()

    #if !targetEnvironment(simulator)
    let bleTransport = BLETransport()
    let tcpTransport = TcpTransport()
    var transport: TcpTransport { tcpTransport }
    #endif

    private var cancellables = Set<AnyCancellable>()

    init(label: String) {
        self.label = label
        runner.$isRunning
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        #if !targetEnvironment(simulator)
        bleTransport.$connectionState
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        bleTransport.$connectedPeripheralName
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        bleTransport.$batteryLevel
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        tcpTransport.$isReady
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        tcpTransport.$statusMessage
            .sink { [weak self] _ in self?.refreshDerivedStatus() }
            .store(in: &cancellables)
        #endif
        refreshDerivedStatus()
    }

    func noteGaugeSoC(_ soc: Int) {
        guard (0...100).contains(soc) else { return }
        if gaugeSoC != soc {
            gaugeSoC = soc
            refreshDerivedStatus()
        }
    }

    // MARK: - Status

    private func refreshDerivedStatus() {
        let running = runner.isRunning
        if isRunning != running { isRunning = running }
        #if targetEnvironment(simulator)
        let nextStatus = running ? "USB direct (sim)" : "Stopped"
        if statusMessage != nextStatus { statusMessage = nextStatus }
        if batteryLevel != nil { batteryLevel = nil }
        if isTransportReady != true { isTransportReady = true }
        #else
        let nextStatus: String
        let nextReady: Bool
        let nextBattery: Int?
        switch selectedTransportMode {
        case .ble:
            if let name = bleTransport.connectedPeripheralName {
                nextStatus = "BLE: \(name) (\(bleTransport.connectionState.rawValue))"
            } else {
                nextStatus = "BLE: \(bleTransport.connectionState.rawValue)"
            }
            nextReady = bleTransport.connectionState == .ready
            let bleBatt = bleTransport.batteryLevel.flatMap { (0...100).contains($0) ? $0 : nil }
            nextBattery = bleBatt ?? gaugeSoC
        case .wifiDirect:
            nextStatus = tcpTransport.statusMessage
            nextReady = true
            nextBattery = bleTransport.batteryLevel.flatMap { (0...100).contains($0) ? $0 : nil } ?? gaugeSoC
        }
        if statusMessage != nextStatus { statusMessage = nextStatus }
        if isTransportReady != nextReady { isTransportReady = nextReady }
        if batteryLevel != nextBattery { batteryLevel = nextBattery }
        #endif
    }

    // MARK: - Lifecycle

    /// Full boot — for BLE mode this is called only after BLE reaches .ready.
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
        engine.append(raw: "[=] boot: \(bundledURL?.path ?? "none")", isInput: false)
        do {
            try await runner.launch()
        } catch {
            engine.append(raw: "[!] boot: launch failed — \(error.localizedDescription)", isInput: false)
            return
        }
        if runner.portMasterFD >= 0 {
            switch selectedTransportMode {
            case .ble:
                bleTransport.attach(portFD: runner.portMasterFD)
            case .wifiDirect(let host, let port):
                tcpTransport.connect(host: host, port: port)
                tcpTransport.attach(portFD: runner.portMasterFD)
            }
        }
        Task { await engine.connect(to: runner) }
        #endif
    }

    /// For BLE mode: connect to a scanned peripheral, wait for service discovery to
    /// complete (.ready), then boot pm3 client so the relay is wired up correctly.
    #if !targetEnvironment(simulator)
    func connectBLEAndBoot(to discovered: DiscoveredPeripheral, scanHistory: ScanHistoryStore) async {
        bleTransport.connect(to: discovered)
        // Wait until BLE reaches .ready or .error / .disconnected
        for await state in bleTransport.connectionEvents {
            if state == .ready {
                break
            } else if state == .error || state == .disconnected {
                engine.append(raw: "[!] BLE connect failed: \(state.rawValue)", isInput: false)
                return
            }
        }
        // PM3 client boots now, with BLE already attached
        await boot(scanHistory: scanHistory)
    }
    #endif

    /// Terminate the running client (if any) then boot fresh.
    func restart(scanHistory: ScanHistoryStore) async {
        runner.terminate()
        #if !targetEnvironment(simulator)
        if case .ble = selectedTransportMode {
            // For BLE, only re-boot if still connected
            if bleTransport.connectionState == .ready {
                await boot(scanHistory: scanHistory)
            }
            return
        }
        #endif
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
