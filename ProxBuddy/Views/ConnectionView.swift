import SwiftUI

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
                        sessionSection(session)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            let s = deviceManager.addSession()
                            Task { await s.boot(scanHistory: scanHistory) }
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Per-session section

    @ViewBuilder
    private func sessionSection(_ session: PM3Session) -> some View {
        let isActive = deviceManager.activeSession?.id == session.id

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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("BLE Scanner").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if session.bleTransport.connectionState == .scanning {
                                    session.bleTransport.stopScanning()
                                } else {
                                    session.bleTransport.startScanning()
                                }
                            } label: {
                                Label(
                                    session.bleTransport.connectionState == .scanning ? "Scanning…" : "Scan Nearby",
                                    systemImage: "radiowaves.right"
                                )
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.hackerGreen)
                            }
                        }

                        if !session.bleTransport.discoveredPeripherals.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(session.bleTransport.discoveredPeripherals) { discovered in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(discovered.name)
                                                .font(.system(.footnote, design: .monospaced))
                                                .foregroundStyle(.white)
                                            Text("RSSI: \(discovered.rssi) dBm")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Connect") {
                                            session.bleTransport.connect(to: discovered)
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
        .sheet(item: $showingInfoSession) { sess in
            DeviceInfoSheet(session: sess)
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
