import Foundation
import Combine

enum TransportMode: Hashable, Identifiable {
    case ble
    case wifi

    var id: String {
        switch self {
        case .ble: return "ble"
        case .wifi: return "wifi"
        }
    }
}

enum BWMWiFiParse {
    /// Pulls host/port from `hw bwmwifi` output (`BWM on WiFi at …` / `pm3 -p tcp:…`).
    static func endpoint(from lines: [String]) -> (host: String, port: UInt16)? {
        let text = lines.joined(separator: "\n")
        if let match = text.firstMatch(of: /tcp:([0-9A-Za-z._-]+):(\d+)/) {
            let host = String(match.1)
            if let port = UInt16(match.2), port > 0 {
                return (host, port)
            }
        }
        if let match = text.firstMatch(of: /BWM on WiFi at ([0-9A-Za-z._-]+)/) {
            return (String(match.1), 7777)
        }
        return nil
    }
}

/// One connected Proxmark — bundles runner, engine, and active transport together.
@MainActor
final class PM3Session: ObservableObject, Identifiable {
    private static let wifiHostKey = "com.proxbuddy.wifi.host"
    private static let wifiPortKey = "com.proxbuddy.wifi.port"
    private static let wifiSSIDKey = "com.proxbuddy.wifi.ssid"

    let id = UUID()
    @Published var label: String
    @Published private(set) var isDemo = false
    @Published var selectedTransportMode: TransportMode = .ble {
        didSet { refreshDerivedStatus() }
    }
    @Published var wifiHost: String {
        didSet { UserDefaults.standard.set(wifiHost, forKey: Self.wifiHostKey) }
    }
    @Published var wifiPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(wifiPort), forKey: Self.wifiPortKey) }
    }
    @Published var wifiSSID: String {
        didSet { UserDefaults.standard.set(wifiSSID, forKey: Self.wifiSSIDKey) }
    }
    @Published var wifiPassword = ""
    @Published var wifiConnecting = false {
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
    #endif

    private var cancellables = Set<AnyCancellable>()

    init(label: String) {
        self.label = label
        self.wifiHost = UserDefaults.standard.string(forKey: Self.wifiHostKey) ?? ""
        let storedPort = UserDefaults.standard.integer(forKey: Self.wifiPortKey)
        self.wifiPort = (1...65535).contains(storedPort) ? UInt16(storedPort) : 7777
        self.wifiSSID = UserDefaults.standard.string(forKey: Self.wifiSSIDKey) ?? ""
        // `@Published` emits in `willSet`, so a sink that re-reads `runner.isRunning`
        // still sees the previous value. Use the published flag itself.
        runner.$isRunning
            .sink { [weak self] running in
                guard let self else { return }
                if self.isRunning != running { self.isRunning = running }
                self.refreshDerivedStatus()
            }
            .store(in: &cancellables)
        #if !targetEnvironment(simulator)
        bleTransport.$connectionState
            .sink { [weak self] _ in self?.scheduleStatusRefresh() }
            .store(in: &cancellables)
        bleTransport.$connectedPeripheralName
            .sink { [weak self] _ in self?.scheduleStatusRefresh() }
            .store(in: &cancellables)
        bleTransport.$batteryLevel
            .sink { [weak self] _ in self?.scheduleStatusRefresh() }
            .store(in: &cancellables)
        #endif
        refreshDerivedStatus()
    }

    /// Run after the current `@Published` willSet so property reads see the new value.
    private func scheduleStatusRefresh() {
        Task { @MainActor [weak self] in
            self?.refreshDerivedStatus()
        }
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
        if isDemo {
            let demoStatus = "Demo — UI only"
            if statusMessage != demoStatus { statusMessage = demoStatus }
            if isTransportReady { isTransportReady = false }
            if batteryLevel != nil { batteryLevel = nil }
            return
        }

        let running = isRunning
        #if targetEnvironment(simulator)
        let nextStatus = running ? "USB direct (sim)" : "Stopped"
        if statusMessage != nextStatus { statusMessage = nextStatus }
        if batteryLevel != nil { batteryLevel = nil }
        if isTransportReady != true { isTransportReady = true }
        #else
        let nextStatus: String
        let nextReady: Bool
        let nextBattery: Int?
        let bleBatt = bleTransport.batteryLevel.flatMap { (0...100).contains($0) ? $0 : nil }
        nextBattery = bleBatt ?? gaugeSoC
        switch selectedTransportMode {
        case .ble:
            if let name = bleTransport.connectedPeripheralName {
                nextStatus = "BLE: \(name) (\(bleTransport.connectionState.rawValue))"
            } else {
                nextStatus = "BLE: \(bleTransport.connectionState.rawValue)"
            }
            nextReady = bleTransport.connectionState == .ready
        case .wifi:
            let host = wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = host.isEmpty ? "tcp:?:\(wifiPort)" : "tcp:\(host):\(wifiPort)"
            if wifiConnecting {
                nextStatus = "Wi-Fi: connecting \(endpoint)"
                nextReady = false
            } else if running {
                nextStatus = "Wi-Fi: \(endpoint)"
                nextReady = true
            } else {
                nextStatus = "Wi-Fi: disconnected"
                nextReady = false
            }
        }
        if statusMessage != nextStatus { statusMessage = nextStatus }
        if isTransportReady != nextReady { isTransportReady = nextReady }
        if batteryLevel != nextBattery { batteryLevel = nextBattery }
        #endif
    }

    // MARK: - Lifecycle

    /// Browse Commands / builder without hardware. Does not boot the client.
    func enterDemo() {
        #if !targetEnvironment(simulator)
        if bleTransport.connectionState == .scanning {
            bleTransport.stopScanning()
        }
        bleTransport.disconnect()
        #endif
        runner.terminate()
        isDemo = true
        engine.isDemo = true
        refreshDerivedStatus()
        engine.append(raw: "[=] Demo mode. Browse Commands and the builder. Nothing is sent to hardware.", isInput: false)
    }

    func exitDemo() {
        guard isDemo else { return }
        isDemo = false
        engine.isDemo = false
        refreshDerivedStatus()
    }

    /// Full boot — for BLE mode this is called only after BLE reaches .ready.
    func boot(scanHistory: ScanHistoryStore) async {
        exitDemo()
        engine.scanHistory = scanHistory
        runner.resetStream()

        #if targetEnvironment(simulator)
        guard let pm3  = SimulatorBoot.pm3BinaryPath() else {
            engine.append(raw: "[!] boot: no host proxmark3 binary found — set SimulatorBoot.clientPath", isInput: false)
            return
        }
        guard let port = SimulatorBoot.usbSerialPort()  else {
            engine.append(raw: "[!] boot: no USB serial port", isInput: false)
            return
        }
        engine.append(raw: "[=] sim: \(pm3) · \(port)", isInput: false)
        NSLog("[ProxBuddy] sim client \(pm3) port \(port)")
        do {
            try await runner.launch(binaryPath: pm3, portPath: port)
        } catch {
            engine.append(raw: "[!] boot: launch failed — \(error.localizedDescription)", isInput: false)
            return
        }
        Task { await engine.connect(to: runner) }

        #else
        let bundledURL = PM3ClientVersion.bundledDylibURL()
        engine.append(raw: "[=] boot: \(bundledURL?.path ?? "none")", isInput: false)
        do {
            switch selectedTransportMode {
            case .ble:
                try await runner.launch { [weak self] fd in
                    self?.bleTransport.attach(portFD: fd)
                }
            case .wifi:
                let host = wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else {
                    engine.append(raw: "[!] Wi-Fi: enter the BWM IP or hostname", isInput: false)
                    return
                }
                let spec = "tcp:\(host):\(wifiPort)"
                engine.append(raw: "[=] opening \(spec)", isInput: false)
                try await runner.launch(tcpHost: host, tcpPort: wifiPort)
            }
        } catch {
            engine.append(raw: "[!] boot: launch failed — \(error.localizedDescription)", isInput: false)
            runner.terminate()
            return
        }
        Task { await engine.connect(to: runner) }
        #endif
    }

    /// For BLE mode: connect to a scanned peripheral, wait for service discovery to
    /// complete (.ready), then boot pm3 client so the relay is wired up correctly.
    #if !targetEnvironment(simulator)
    func connectBLEAndBoot(to discovered: DiscoveredPeripheral, scanHistory: ScanHistoryStore) async {
        if runner.isRunning {
            runner.terminate()
        }
        selectedTransportMode = .ble
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

    /// libpm3 opens `tcp:host:port` itself — same as desktop `pm3 -p tcp:…`.
    func connectWiFi(scanHistory: ScanHistoryStore) async {
        let host = wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            engine.append(raw: "[!] Wi-Fi: enter the BWM IP or hostname", isInput: false)
            return
        }
        selectedTransportMode = .wifi
        wifiConnecting = true
        defer { wifiConnecting = false }
        await restart(scanHistory: scanHistory)
    }

    /// Join the BWM to STA Wi-Fi over the current (BLE) client and fill host/port.
    func bringUpWiFi() async {
        guard runner.isRunning else {
            engine.append(raw: "[!] Wi-Fi: connect over BLE first, then join a network", isInput: false)
            return
        }
        let ssid = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            engine.append(raw: "[!] Wi-Fi: SSID is required", isInput: false)
            return
        }
        var parts = ["hw bwmwifi", "--ssid", Self.cliToken(ssid)]
        let pwd = wifiPassword
        if !pwd.isEmpty {
            parts += ["--pwd", Self.cliToken(pwd)]
        }
        parts += ["--port", "\(wifiPort)"]
        let cmd = parts.joined(separator: " ")
        wifiConnecting = true
        defer { wifiConnecting = false }
        engine.append(raw: "[=] \(cmd) — join can take ~15s", isInput: false)
        let lines = await engine.captureOutput(cmd)
        if let parsed = BWMWiFiParse.endpoint(from: lines) {
            wifiHost = parsed.host
            wifiPort = parsed.port
            engine.append(raw: "[+] BWM on WiFi at \(parsed.host):\(parsed.port)", isInput: false)
        } else {
            engine.append(raw: "[!] Wi-Fi: bring-up did not report an IP — check SSID/password", isInput: false)
        }
    }

    private static func cliToken(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0.isWhitespace || "\"'\\".contains($0) })
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
        bleTransport.disconnect()
        #endif
        await boot(scanHistory: scanHistory)
    }

    func terminate() {
        exitDemo()
        runner.terminate()
        #if !targetEnvironment(simulator)
        bleTransport.disconnect()
        #endif
    }
}
