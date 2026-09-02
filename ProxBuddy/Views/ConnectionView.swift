import SwiftUI
import Combine

struct DevicesView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var scanHistory:   ScanHistoryStore
    @EnvironmentObject var appNav:        AppNavigation

    @State private var editingLabel: UUID?
    @State private var labelDraft   = ""
    @State private var showingInfoSession: PM3Session?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(deviceManager.sessions) { session in
                        SessionCardView(
                            session: session,
                            editingLabel: $editingLabel,
                            labelDraft: $labelDraft,
                            showingInfoSession: $showingInfoSession
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            _ = deviceManager.addSession()
                            // BLE sessions connect & boot via the scanner UI;
                            // non-BLE sessions would boot here but BLE is the default.
                        } label: {
                            Label("Add Device", systemImage: "plus.circle.fill")
                                .foregroundStyle(.hackerGreen)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .liquidGlassCard()
                    }
                }
                .padding()
            }
            .hackerBackground()
            .navigationTitle("Devices & PM5")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(item: $showingInfoSession) { sess in
            DeviceInfoSheet(session: sess)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Per-session Card View

private struct SessionCardView: View {
    @ObservedObject var session: PM3Session
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var scanHistory:   ScanHistoryStore
    @EnvironmentObject var appNav:        AppNavigation
    @Binding var editingLabel: UUID?
    @Binding var labelDraft: String
    @Binding var showingInfoSession: PM3Session?

    private var isActive: Bool {
        deviceManager.activeSession?.id == session.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.label.uppercased())
                .hackerText()
                .font(.subheadline)
                .opacity(0.8)

            VStack(alignment: .leading, spacing: 16) {
                // Label row — tap to rename
                HStack {
                    if editingLabel == session.id {
                        TextField("Device name", text: $labelDraft)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8)
                            .background(Color.black.opacity(0.3).cornerRadius(8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                            .onSubmit {
                                let trimmed = labelDraft.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty { session.label = trimmed }
                                editingLabel = nil
                            }
                        Button("Done") {
                            let trimmed = labelDraft.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { session.label = trimmed }
                            editingLabel = nil
                        }
                        .foregroundStyle(.hackerGreen)
                    } else {
                        Image(systemName: session.isDemo ? "play.rectangle" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle((session.isRunning || session.isDemo) ? .hackerGreen : .secondary)
                            .frame(width: 22)
                        Text(session.label)
                            .hackerText()
                            .fontWeight(isActive ? .semibold : .regular)
                        Spacer()

                        #if !targetEnvironment(simulator)
                        if let level = session.batteryLevel {
                            HStack(spacing: 4) {
                                Image(systemName: batteryIcon(for: level))
                                    .foregroundStyle(level > 20 ? .hackerGreen : .red)
                                Text("\(level)%")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Capsule())
                        }
                        #endif

                        if isActive {
                            Text("ACTIVE")
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.hackerGreen.opacity(0.15))
                                .foregroundStyle(.hackerGreen)
                                .clipShape(Capsule())
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editingLabel != session.id {
                        deviceManager.setActive(session)
                    }
                }
                .onLongPressGesture {
                    labelDraft = session.label
                    editingLabel = session.id
                }

                Divider().background(Color.glassBorder)

                #if !targetEnvironment(simulator)
                // Transport Mode Selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("TRANSPORT SELECTION")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Picker("Transport", selection: Binding(
                        get: { session.selectedTransportMode },
                        set: { newMode in
                            if session.selectedTransportMode == newMode { return }
                            #if !targetEnvironment(simulator)
                            if case .ble = session.selectedTransportMode,
                               session.bleTransport.connectionState == .scanning {
                                session.bleTransport.stopScanning()
                            }
                            #endif
                            session.selectedTransportMode = newMode
                        }
                    )) {
                        Text("PM5 BLE").tag(TransportMode.ble)
                        Text("Wi-Fi").tag(TransportMode.wifi)
                    }
                    .pickerStyle(.segmented)
                }

                // BLE Connection / Scanner Details
                if case .ble = session.selectedTransportMode {
                    BLEScannerSection(session: session, scanHistory: scanHistory)
                }

                if case .wifi = session.selectedTransportMode {
                    WiFiSection(session: session, scanHistory: scanHistory)
                }

                Divider().background(Color.glassBorder)
                #endif

                // Status
                HStack {
                    Text("Transport").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(session.statusMessage).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }

                HStack {
                    Text("pm3 client").font(.system(.caption, design: .monospaced)).foregroundStyle(session.isRunning ? .hackerGreen : .secondary)
                    Spacer()
                    Text(session.isDemo ? "Not running (demo)" : (session.isRunning ? "Running" : "Stopped"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(session.isRunning ? .hackerGreen : .secondary)
                }

                Divider().background(Color.glassBorder)

                Button {
                    deviceManager.setActive(session)
                    if session.isDemo {
                        appNav.selectedTab = 1
                    } else {
                        session.enterDemo()
                        appNav.selectedTab = 1
                    }
                } label: {
                    Label(
                        session.isDemo ? "Open Commands (demo)" : "Try demo (no hardware)",
                        systemImage: "play.rectangle"
                    )
                }
                .foregroundStyle(.hackerGreen)

                if session.isDemo {
                    Button {
                        session.exitDemo()
                    } label: {
                        Label("Leave demo", systemImage: "stop.circle")
                    }
                    .foregroundStyle(.secondary)
                }

                Divider().background(Color.glassBorder)

                // Actions
                if session.isTransportReady {
                    if session.isRunning {
                        Button {
                            showingInfoSession = session
                        } label: {
                            Label("Device Specs & Hardware Info", systemImage: "info.circle")
                        }
                        .foregroundStyle(.hackerGreen)

                        Button(role: .destructive) {
                            Task { await session.restart(scanHistory: scanHistory) }
                        } label: {
                            Label("Restart pm3 Client", systemImage: "arrow.counterclockwise")
                        }
                    } else {
                        Button {
                            Task { await session.restart(scanHistory: scanHistory) }
                        } label: {
                            Label("Start pm3 Client", systemImage: "play.fill")
                        }
                        .foregroundStyle(.hackerGreen)
                    }
                }

                // Session log
                if let logURL = session.engine.sessionLogURL {
                    ShareLink(item: logURL) {
                        Label("Export Session Log", systemImage: "square.and.arrow.up")
                    }
                }
                if deviceManager.sessions.count > 1 {
                    Button(role: .destructive) {
                        deviceManager.removeSession(session)
                    } label: {
                        Label("Remove Device", systemImage: "trash")
                    }
                }
            }
            .liquidGlassCard()
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 0..<20: return "battery.25"
        case 20..<50: return "battery.50"
        case 50..<80: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - BLE Scanner Section

#if !targetEnvironment(simulator)
private struct BLEScannerSection: View {
    @ObservedObject var session: PM3Session
    @ObservedObject var ble: BLETransport
    var scanHistory: ScanHistoryStore

    init(session: PM3Session, scanHistory: ScanHistoryStore) {
        self.session = session
        self.scanHistory = scanHistory
        self.ble = session.bleTransport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + scan toggle
            HStack {
                Text("BLE SCANNER")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                stateLabel
            }

            // Already connected — show name + disconnect option
            if ble.connectionState == .ready, let name = ble.connectedPeripheralName {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.hackerGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("BLE connected · pm3 running")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") {
                        session.bleTransport.disconnect()
                        session.runner.terminate()
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                }
                .padding(8)
                .background(Color.hackerGreen.opacity(0.08))
                .cornerRadius(6)

            } else if ble.connectionState == .connecting || ble.connectionState == .discoveringServices {
                // In-progress connection indicator
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.hackerGreen)
                        .scaleEffect(0.8)
                    Text(ble.connectionState == .connecting ? "Connecting…" : "Discovering services…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

            } else {
                // Scan controls
                HStack {
                    Spacer()
                    Button {
                        if ble.connectionState == .scanning {
                            ble.stopScanning()
                        } else {
                            ble.startScanning()
                        }
                    } label: {
                        Label(
                            ble.connectionState == .scanning ? "Stop" : "Scan Nearby",
                            systemImage: ble.connectionState == .scanning ? "stop.circle" : "antenna.radiowaves.left.and.right"
                        )
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ble.connectionState == .scanning ? .red : .hackerGreen)
                    }
                }

                if ble.connectionState == .scanning && ble.discoveredPeripherals.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.hackerGreen)
                            .scaleEffect(0.7)
                        Text("Scanning for PM5 devices…")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !ble.discoveredPeripherals.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(ble.discoveredPeripherals) { discovered in
                            HStack(spacing: 10) {
                                Image(systemName: "wave.3.right")
                                    .foregroundStyle(.hackerGreen)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(discovered.name)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.white)
                                    Text("RSSI: \(discovered.rssi) dBm")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Connect") {
                                    Task {
                                        await session.connectBLEAndBoot(
                                            to: discovered,
                                            scanHistory: scanHistory
                                        )
                                    }
                                }
                                .font(.system(.caption, design: .monospaced))
                                .buttonStyle(.borderedProminent)
                                .tint(.hackerGreen)
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
        .onAppear {
            // Auto-start scanning when the user opens a BLE session
            // (only if BT is on and not already connected/scanning)
            let state = ble.connectionState
            if state == .disconnected || state == .error {
                ble.startScanning()
            }
        }
        .onDisappear {
            // Stop scanning to save battery when navigating away
            if ble.connectionState == .scanning {
                ble.stopScanning()
            }
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        let (label, color): (String, Color) = {
            switch ble.connectionState {
            case .disconnected:   return ("OFFLINE", .secondary)
            case .scanning:       return ("SCANNING", .orange)
            case .connecting:     return ("CONNECTING", .yellow)
            case .discoveringServices: return ("NEGOTIATING", .yellow)
            case .ready:          return ("CONNECTED", .hackerGreen)
            case .error:          return ("ERROR", .red)
            }
        }()
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Wi-Fi (STA + TCP)

private struct WiFiSection: View {
    @ObservedObject var session: PM3Session
    var scanHistory: ScanHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WI-FI (STA + TCP)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(onTCP ? "CONNECTED" : (session.wifiConnecting ? "CONNECTING" : "OFFLINE"))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((onTCP ? Color.hackerGreen : (session.wifiConnecting ? Color.yellow : Color.secondary)).opacity(0.15))
                    .foregroundStyle(onTCP ? .hackerGreen : (session.wifiConnecting ? .yellow : .secondary))
                    .clipShape(Capsule())
            }

            Text("Once the BWM is on Wi-Fi (hw bwmwifi over BLE or USB, once), skip BLE — Connect with the IP it printed. Default port 7777. No mDNS.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("192.168.1.77", text: $session.wifiHost)
                    .textFieldStyle(.plain)
                    .font(.system(.footnote, design: .monospaced))
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .padding(8)
                    .background(Color.black.opacity(0.3).cornerRadius(8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                    .onSubmit {
                        Task { await session.connectWiFi(scanHistory: scanHistory) }
                    }
                TextField("7777", text: portBinding)
                    .textFieldStyle(.plain)
                    .font(.system(.footnote, design: .monospaced))
                    .keyboardType(.numberPad)
                    .frame(width: 64)
                    .padding(8)
                    .background(Color.black.opacity(0.3).cornerRadius(8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
            }

            if onTCP {
                Button("Disconnect") {
                    session.terminate()
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
            } else {
                Button {
                    Task { await session.connectWiFi(scanHistory: scanHistory) }
                } label: {
                    if session.wifiConnecting {
                        Label("Connecting…", systemImage: "hourglass")
                    } else if session.runner.isRunning {
                        Label("Switch to Wi-Fi", systemImage: "wifi")
                    } else {
                        Label("Connect", systemImage: "wifi")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .buttonStyle(.borderedProminent)
                .tint(.hackerGreen)
                .disabled(session.wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.wifiConnecting)
            }

            Divider().background(Color.glassBorder)

            Text("BRING UP FROM BLE")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            if session.runner.isRunning {
                TextField("SSID", text: $session.wifiSSID)
                    .textFieldStyle(.plain)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                    .background(Color.black.opacity(0.3).cornerRadius(8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                SecureField("Password (omit if open)", text: $session.wifiPassword)
                    .textFieldStyle(.plain)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                    .background(Color.black.opacity(0.3).cornerRadius(8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                Button {
                    Task { await session.bringUpWiFi() }
                } label: {
                    Label("Join network (hw bwmwifi)", systemImage: "antenna.radiowaves.left.and.right")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.hackerGreen)
                .disabled(session.wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.wifiConnecting)
            } else {
                Text("Connect over BLE first, then join a network here — or type an IP from another client.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var onTCP: Bool {
        session.runner.isRunning && session.runner.portMasterFD < 0
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(session.wifiPort) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if digits.isEmpty { return }
                if let v = UInt16(digits), v > 0 {
                    session.wifiPort = v
                }
            }
        )
    }
}
#endif
