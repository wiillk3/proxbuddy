import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var engine:        TerminalEngine
    @EnvironmentObject var appNav:        AppNavigation
    @EnvironmentObject var deviceManager: DeviceManager
    #if !targetEnvironment(simulator)
    @EnvironmentObject var tcp: TcpTransport
    @EnvironmentObject var ble: BLETransport
    #endif

    @State private var inputText = ""
    @State private var showTimestamps = false
    @State private var showDataPlot = false
    @State private var plotSamples: [Double] = []
    @State private var isCapturingPlot = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Device picker — iPhone only, when more than one session exists
            if deviceManager.sessions.count > 1
                && UIDevice.current.userInterfaceIdiom == .phone {
                devicePicker
            }
            statusBar
            Color.white.opacity(0.08).frame(height: 1)
            outputScroll
            Color.white.opacity(0.08).frame(height: 1)
            inputBar
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
                engine.isAutoScrolling = true
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

    // MARK: - Output scroll

    private var outputScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(engine.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            ANSIText(
                                raw: line.raw,
                                showTimestamp: showTimestamps,
                                timestamp: line.timestamp,
                                isInput: line.isInput
                            )
                            if let cmd = hintCommand(from: line.raw) {
                                HintCommandChip(command: cmd) {
                                    inputText = cmd
                                    inputFocused = true
                                } onLongPress: {
                                    appNav.browserPath = [.builder(cmd)]
                                    appNav.selectedTab = 1
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .id(line.id)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                inputFocused = false
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in engine.isAutoScrolling = false }
            )
            .onChange(of: engine.lines.count) { _, _ in
                guard engine.isAutoScrolling, let last = engine.lines.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !engine.isAutoScrolling {
                    Button {
                        engine.isAutoScrolling = true
                        if let last = engine.lines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                            .padding(12)
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 0) {
            Text("pm3")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(red: 0.0, green: 0.8, blue: 0.2))
                .onTapGesture { navigateHistory(.up) }
            Text(" -->")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(red: 0.0, green: 0.8, blue: 0.2))
                .onTapGesture { navigateHistory(.down) }
            Spacer().frame(width: 6)
            TextField("", text: $inputText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.green)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($inputFocused)
                .onSubmit { submitCommand() }
                .onKeyPress(.upArrow)   { navigateHistory(.up);   return .handled }
                .onKeyPress(.downArrow) { navigateHistory(.down); return .handled }

            if !inputText.isEmpty {
                Button { submitCommand() } label: {
                    Image(systemName: "return")
                        .foregroundStyle(Color(red: 0.0, green: 0.8, blue: 0.2))
                }
                .padding(.trailing, inputFocused ? 8 : 0)
            }

            if inputFocused {
                Button {
                    inputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16))
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.05))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { navigateHistory(.up) } label: {
                    Image(systemName: "arrow.up")
                }
                Button { navigateHistory(.down) } label: {
                    Image(systemName: "arrow.down")
                }
                Button("Tab") {
                    inputText += " "
                }
                Spacer()
                Button("Done") {
                    inputFocused = false
                }
                .fontWeight(.semibold)
                .foregroundStyle(.green)
            }
        }
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

    private func submitCommand() {
        engine.sendCommand(inputText)
        inputText = ""
        engine.isAutoScrolling = true
        engine.resetHistoryNavigation()
    }

    private enum HistoryDir { case up, down }
    private func navigateHistory(_ dir: HistoryDir) {
        inputText = dir == .up ? (engine.historyUp() ?? inputText)
                               : (engine.historyDown() ?? inputText)
    }

    // Extract the command from a pm3 hint line, e.g. [?] Hint: Try `hf mf info`
    private func hintCommand(from raw: String) -> String? {
        // Strip ANSI first — pm3 may inject color codes inside "[?]" splitting the literal
        let stripped = raw.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "",
                                                 options: .regularExpression)
        guard stripped.contains("[?]") else { return nil }
        // backtick-quoted: `cmd`
        if let r = stripped.range(of: #"`([^`]+)`"#, options: .regularExpression) {
            let m = String(stripped[r])
            return String(m.dropFirst().dropLast())
        }
        // single-quoted: 'cmd'
        if let r = stripped.range(of: #"'([a-z][^']+)'"#, options: .regularExpression) {
            let m = String(stripped[r])
            return String(m.dropFirst().dropLast())
        }
        return nil
    }
}

struct HintCommandChip: View {
    let command: String
    let onTap: () -> Void
    let onLongPress: () -> Void
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Text(command)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(pressed ? Color.green.opacity(0.25) : Color.green.opacity(0.15))
        .foregroundStyle(Color.green)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.green.opacity(0.5), lineWidth: 1))
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.easeInOut(duration: 0.1), value: pressed)
        .onLongPressGesture(minimumDuration: 0.5, pressing: { isPressing in
            pressed = isPressing
        }, perform: {
            onLongPress()
        })
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pressed = false }
            onTap()
        }
    }
}
