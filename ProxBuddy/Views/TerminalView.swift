import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var engine:        TerminalEngine
    @EnvironmentObject var appNav:        AppNavigation
    @EnvironmentObject var deviceManager: DeviceManager
    #if !targetEnvironment(simulator)
    @EnvironmentObject var tcp: TcpTransport
    @EnvironmentObject var ble: BLETransport
    #endif

    @State private var showTimestamps = false
    @State private var showDataPlot = false
    @State private var plotSamples: [Double] = []
    @State private var isAutoScrolling = true
    @State private var externalInputText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Device picker — iPhone only, when more than one session exists
            if deviceManager.sessions.count > 1
                && UIDevice.current.userInterfaceIdiom == .phone {
                devicePicker
            }
            statusBar
            Color.white.opacity(0.08).frame(height: 1)
            
            ZStack(alignment: .bottomTrailing) {
                TerminalTableView(
                    engine: engine,
                    showTimestamps: showTimestamps,
                    isAutoScrolling: $isAutoScrolling,
                    onHintTap: { cmd in
                        externalInputText = cmd
                    },
                    onHintLongPress: { cmd in
                        appNav.browserPath = [.builder(cmd)]
                        appNav.selectedTab = 1
                    }
                )

                if !isAutoScrolling {
                    Button {
                        isAutoScrolling = true
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                            .padding(12)
                    }
                }
            }

            Color.white.opacity(0.08).frame(height: 1)
            
            TerminalInputBarView(
                externalText: $externalInputText,
                onSend: { text in
                    engine.sendCommand(text)
                    isAutoScrolling = true
                    engine.resetHistoryNavigation()
                },
                onHistoryUp: {
                    engine.historyUp()
                },
                onHistoryDown: {
                    engine.historyDown()
                }
            )
            .frame(height: 48)
        }
        .background(Color.black)
        .sheet(isPresented: $showDataPlot) {
            DataPlotView(samples: plotSamples)
        }
        .onChange(of: engine.pendingPlotSamples) {
            guard let s = engine.pendingPlotSamples else { return }
            plotSamples = s
            showDataPlot = true
            engine.pendingPlotSamples = nil
        }
        .onChange(of: appNav.selectedTab) { _, tab in
            if tab == AppNavigation.terminalTab {
                isAutoScrolling = true
            }
        }
    }

    // MARK: - Device picker (iPhone, 2+ sessions)

    private var devicePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(deviceManager.sessions) { session in
                    let isActive = deviceManager.activeSession?.id == session.id
                    Button {
                        deviceManager.setActive(session)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(session.isRunning ? Color.green : Color.yellow)
                                .frame(width: 6, height: 6)
                            Text(session.label)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(isActive ? Color.green.opacity(0.2) : Color.white.opacity(0.07))
                        .foregroundStyle(isActive ? .green : .gray)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 5)
        .background(Color(white: 0.06))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.gray)
            Spacer()
            Toggle("TS", isOn: $showTimestamps)
                .font(.system(.caption2, design: .monospaced))
                .toggleStyle(.button)
                .tint(.gray)
            Button { engine.clearDisplay() } label: {
                Image(systemName: "trash").font(.caption)
            }
            .foregroundStyle(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.07))
    }

    // MARK: - Helpers

    private var connectionColor: Color {
        #if targetEnvironment(simulator)
        return .green
        #else
        if let session = deviceManager.activeSession {
            switch session.selectedTransportMode {
            case .ble:
                return (ble.connectionState == .ready && session.isRunning) ? .green : .yellow
            case .wifiDirect, .bridge:
                return (tcp.isReady && session.isRunning) ? .green : .yellow
            }
        }
        return .yellow
        #endif
    }

    private var connectionLabel: String {
        #if targetEnvironment(simulator)
        return "USB direct"
        #else
        if let session = deviceManager.activeSession {
            return session.statusMessage
        }
        return tcp.statusMessage
        #endif
    }
}
