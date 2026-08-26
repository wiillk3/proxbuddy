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
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(session.isRunning ? .hackerGreen : .secondary)
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
                            session.selectedTransportMode = newMode
                            Task { await session.restart(scanHistory: scanHistory) }
                        }
                    )) {
                        Text("PM5 BLE").tag(TransportMode.ble)
                        Text("Wi-Fi Direct").tag(TransportMode.wifiDirect(host: "192.168.1.50", port: 9099))
                        Text("Mac Bridge").tag(TransportMode.bridge)
                    }
                    .pickerStyle(.segmented)
                }

                // BLE Connection / Scanner Details
                if case .ble = session.selectedTransportMode {
                    BLEScannerSection(session: session, scanHistory: scanHistory)
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
                    Text(session.isRunning ? "Running" : "Stopped").font(.system(.caption, design: .monospaced)).foregroundStyle(session.isRunning ? .hackerGreen : .secondary)
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
#endif

// MARK: - Device Info & Hardware Specs Sheet

struct DeviceInfoSheet: View {
    @ObservedObject var session: PM3Session
    @Environment(\.dismiss) var dismiss

    @State private var isLoading = true
    @State private var armVersion: String = "Querying..."
    @State private var armStatus: String = "Querying..."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // PM5 ARM Hardware
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PROXMARK5 ARM HARDWARE")
                            .hackerText().font(.caption).opacity(0.8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(title: "Architecture", value: "Proxmark5 ARM (the5 branch)")
                            infoRow(title: "Firmware Build", value: armVersion)
                            infoRow(title: "Hardware Status", value: armStatus)
                        }
                    }
                    .liquidGlassCard()

                    // Wireless BWM Module
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BWM WIRELESS MODULE (ESP32-C2)")
                            .hackerText().font(.caption).opacity(0.8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(title: "Device Model ID", value: "0xDA10 (ESP32-C2)")
                            infoRow(title: "Default Baud Rate", value: "460,800 bps")
                            infoRow(title: "BLE SPP Service", value: "0xAE86 / Data: 0xAE88")
                            infoRow(title: "Battery Gauge (BAS)", value: session.batteryLevel != nil ? "\(session.batteryLevel!)%" : "0x180F / 0x2A19")
                            infoRow(title: "Wi-Fi Mode", value: "Station (Passthrough Server)")
                        }
                    }
                    .liquidGlassCard()

                    // Active Connection Diagnostic
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ACTIVE CONNECTION DIAGNOSTIC")
                            .hackerText().font(.caption).opacity(0.8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(title: "Active Transport", value: session.statusMessage)
                            infoRow(title: "Serial Relay Master FD", value: "\(session.runner.portMasterFD)")
                            infoRow(title: "Client Process State", value: session.isRunning ? "Active" : "Stopped")
                        }
                    }
                    .liquidGlassCard()
                }
                .padding()
            }
            .hackerBackground()
            .navigationTitle("Device Specs & Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.hackerGreen)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshInfo() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.hackerGreen)
                    }
                }
            }
            .task { await refreshInfo() }
        }
        .preferredColorScheme(.dark)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private func refreshInfo() async {
        isLoading = true
        let versionLines = await session.engine.captureOutputSilent("hw version")
        if !versionLines.isEmpty {
            armVersion = versionLines.prefix(2).joined(separator: " · ")
        } else {
            armVersion = "Iceman / PM5 (the5 branch)"
        }

        let statusLines = await session.engine.captureOutputSilent("hw status")
        if !statusLines.isEmpty {
            armStatus = statusLines.prefix(2).joined(separator: " · ")
        } else {
            armStatus = "OK (Standard Operation)"
        }
        isLoading = false
    }
}
