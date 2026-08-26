import Foundation
import SwiftUI

struct TerminalLine: Identifiable, @unchecked Sendable, Equatable {
    let id: UUID
    let raw: String           // original text with ANSI codes
    let timestamp: Date
    let isInput: Bool
    let hint: String?
    let attributedText: AttributedString
    let nsAttributedText: NSAttributedString

    init(id: UUID = UUID(), raw: String, timestamp: Date, isInput: Bool) {
        self.id = id
        self.raw = raw
        self.timestamp = timestamp
        self.isInput = isInput
        self.hint = TerminalLine.extractHint(from: raw)
        self.attributedText = ANSIParser.parse(
            raw,
            fontSize: 13,
            defaultColor: isInput ? ANSIParser.inputDefault : ANSIParser.outputDefault
        )
        self.nsAttributedText = ANSIParser.parseNS(
            raw,
            fontSize: 13,
            defaultColor: isInput ? ANSIParser.inputDefaultUI : ANSIParser.outputDefaultUI
        )
    }

    private static func extractHint(from raw: String) -> String? {
        guard raw.contains("[?]") else { return nil }
        if let first = raw.firstIndex(of: "`"), let last = raw[raw.index(after: first)...].firstIndex(of: "`") {
            let cmd = String(raw[raw.index(after: first)..<last])
            if !cmd.isEmpty { return cmd }
        }
        if let first = raw.firstIndex(of: "'"), let last = raw[raw.index(after: first)...].firstIndex(of: "'") {
            let cmd = String(raw[raw.index(after: first)..<last])
            if !cmd.isEmpty { return cmd }
        }
        return nil
    }

    static func == (lhs: TerminalLine, rhs: TerminalLine) -> Bool {
        lhs.id == rhs.id && lhs.raw == rhs.raw && lhs.isInput == rhs.isInput
    }
}

@MainActor
final class TerminalEngine: ObservableObject {
    @Published var lines: [TerminalLine] = []
    @Published var isAutoScrolling = true
    @Published var pendingInputText: String? = nil

    private(set) var history: [String] = []
    private var historyIndex = -1

    private var sessionLogHandle: FileHandle?
    private(set) var sessionLogURL: URL?

    private let historyKey = "com.proxbuddy.commandHistory"
    private let maxHistory = 500

    private weak var runner: BinaryRunner?

    // Scan history detection — accumulates lines between prompts when not in captureMode
    private var linesSincePrompt: [String] = []
    private var lastSentCommand = ""
    private var lastCommandTimestamp = Date()
    weak var scanHistory: ScanHistoryStore?

    // Capture mode: collect pm3 output until next prompt
    private var captureMode = false
    private var captureSilent = false   // true = don't show captured lines in terminal
    private var captureBuffer: [String] = []
    private var captureContinuation: CheckedContinuation<[String], Never>?

    var isPM3Running: Bool { runner?.isRunning == true }

    /// Set when `data plot` is intercepted — TerminalView observes and shows the chart sheet.
    @Published var pendingPlotSamples: [Double]?

    init() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    // MARK: - Wiring

    func connect(to runner: BinaryRunner, startSession: Bool = true) async {
        self.runner = runner
        if startSession { beginSession() }
        for await raw in runner.outputStream {
            let isLive = raw.hasPrefix("\r")
            let displayLine = isLive ? String(raw.dropFirst()) : raw
            var skipDisplay = false

            let clean = stripAnsi(displayLine)
            let trimmedClean = clean.trimmingCharacters(in: .whitespaces)

            // Ignore pure spinner or line-clearing erase frames (e.g. "[/]" or spaces)
            // that PM3 emits between steps, so they don't erase meaningful text.
            let isBareSpinnerOrEmpty = trimmedClean.isEmpty ||
                trimmedClean == "[/]" || trimmedClean == "[-]" ||
                trimmedClean == "[\\]" || trimmedClean == "[|]"

            if isLive && isBareSpinnerOrEmpty {
                continue
            }

            if captureMode {
                if isBarePrompt(clean) {
                    let silent = captureSilent
                    captureMode = false
                    captureSilent = false
                    let result = captureBuffer
                    captureBuffer = []
                    captureContinuation?.resume(returning: result)
                    captureContinuation = nil
                    if silent { continue }   // also suppress the prompt line
                } else {
                    if !trimmedClean.isEmpty { captureBuffer.append(clean) }
                    if captureSilent { skipDisplay = true }
                }
            } else {
                // Scan detection: accumulate output between prompts
                if isBarePrompt(clean) {
                    if !linesSincePrompt.isEmpty,
                       let record = ScanDetector.detect(lines: linesSincePrompt,
                                                        command: lastSentCommand,
                                                        timestamp: lastCommandTimestamp) {
                        scanHistory?.add(record)
                    }
                    linesSincePrompt.removeAll()
                } else {
                    if !trimmedClean.isEmpty { linesSincePrompt.append(clean) }
                }
            }

            if skipDisplay { continue }

            if isLive {
                let liveTag = TerminalLine(raw: displayLine, timestamp: Date(), isInput: false)
                writeToLog(liveTag)
                if let idx = lines.indices.last, !lines[idx].isInput {
                    lines[idx] = liveTag
                } else {
                    lines.append(liveTag)
                }
            } else {
                append(TerminalLine(raw: raw, timestamp: Date(), isInput: false))
            }
        }
    }

    /// Sends `command --help`, shows it in the terminal, returns stripped output lines.
    func captureCommandHelp(_ baseCommand: String) async -> [String] {
        let cmd = "\(baseCommand.trimmingCharacters(in: .whitespaces)) --help"
        append(TerminalLine(raw: "pm3 --> \(cmd)", timestamp: Date(), isInput: true))
        return await captureRaw(cmd, silent: false)
    }

    /// Sends a command silently (no terminal display) and returns stripped output lines.
    /// Used by the command browser to navigate without cluttering the terminal.
    func captureOutputSilent(_ command: String) async -> [String] {
        return await captureRaw(command, silent: true)
    }

    private func captureRaw(_ command: String, silent: Bool) async -> [String] {
        captureSilent = silent
        captureMode = true
        captureBuffer = []
        runner?.write(command + "\n")
        return await withCheckedContinuation { cont in
            captureContinuation = cont
        }
    }

    private func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
    }

    private func isBarePrompt(_ clean: String) -> Bool {
        guard clean.contains("pm3 -->") else { return false }
        // A real prompt waiting for input ends exactly with "pm3 --> "
        // If it echoes input (e.g. "pm3 --> help") it won't end with "-->"
        return clean.trimmingCharacters(in: .whitespaces).hasSuffix("-->")
    }

    // MARK: - Command

    /// Append a synthetic line to the terminal display (no pm3 write).
    func append(raw: String, isInput: Bool) {
        append(TerminalLine(raw: raw, timestamp: Date(), isInput: isInput))
    }

    func sendCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lower = trimmed.lowercased()
        recordHistory(trimmed)
        lastSentCommand = trimmed
        lastCommandTimestamp = Date()
        append(TerminalLine(raw: "pm3 --> \(trimmed)", timestamp: Date(), isInput: true))

        // GUI-only commands — intercept before they reach pm3
        if lower.hasPrefix("data plot") {
            Task { await captureAndSetPlot() }
            return
        }
        if lower.hasPrefix("data zoom") || lower.hasPrefix("data grid")
            || lower.hasPrefix("data setgraphmarkers") {
            let sub = lower.components(separatedBy: " ").prefix(2).joined(separator: " ")
            append(TerminalLine(
                raw: "[!] \(sub) requires a desktop window — use 'data plot' to view the signal.",
                timestamp: Date(), isInput: false))
            return
        }

        runner?.write(trimmed + "\n")
    }

    private func captureAndSetPlot() async {
        guard isPM3Running else {
            append(TerminalLine(raw: "[!] pm3 is not running.", timestamp: Date(), isInput: false))
            return
        }
        append(TerminalLine(raw: "[=] Capturing signal buffer…", timestamp: Date(), isInput: false))
        let lines = await captureOutputSilent("data print")
        let samples = parseSignalSamples(from: lines)
        if samples.isEmpty {
            append(TerminalLine(
                raw: "[!] No signal data. Graph buffer is empty — capture LF first (e.g. lf read, lf sniff). HF commands do not populate the signal buffer.",
                timestamp: Date(), isInput: false))
        } else {
            append(TerminalLine(raw: "[+] Plotting \(samples.count) samples.", timestamp: Date(), isInput: false))
            pendingPlotSamples = samples
        }
    }

    private func parseSignalSamples(from lines: [String]) -> [Double] {
        var samples: [Double] = []
        for line in lines {
            let clean = line
                .replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\[.\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for token in clean.components(separatedBy: .whitespaces) {
                if let v = Double(token) { samples.append(v) }
            }
        }
        return samples
    }

    // MARK: - History navigation

    func historyUp() -> String? {
        guard !history.isEmpty else { return nil }
        historyIndex = historyIndex == -1 ? history.count - 1 : max(0, historyIndex - 1)
        return history[historyIndex]
    }

    func historyDown() -> String? {
        guard historyIndex >= 0 else { return nil }
        if historyIndex == history.count - 1 {
            historyIndex = -1
            return ""
        }
        historyIndex += 1
        return history[historyIndex]
    }

    func resetHistoryNavigation() {
        historyIndex = -1
    }

    // MARK: - Session log

    func beginSession() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "pm3_\(fmt.string(from: Date())).log"
        let url = docs.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        sessionLogURL = url
        sessionLogHandle = try? FileHandle(forWritingTo: url)
        let header = "=== ProxBuddy session \(Date()) ===\n"
        sessionLogHandle?.write(header.data(using: .utf8) ?? Data())
    }

    func endSession() {
        sessionLogHandle?.closeFile()
        sessionLogHandle = nil
    }

    func clearDisplay() {
        lines.removeAll()
    }

    // MARK: - Private

    private func append(_ line: TerminalLine) {
        writeToLog(line)
        guard shouldDisplay(line.raw) else { return }
        lines.append(line)
    }

    // Lines we never want cluttering the terminal display.
    // macOS simulator artifacts, internal pm3 paths, and OS notification noise
    // that won't appear on a real iOS device.
    private func shouldDisplay(_ raw: String) -> Bool {
        let noisy: [String] = [
            "PasteBoard: Error",
            "LSModifyNotification",
            "scheduleApplicationNotification",
            "NSWorkspaceNotificationCenter",
            "no screens available",
            "Failure on line",
            // CoreSimulator container paths — only appear in simulator
            "/Library/Developer/CoreSimulator/",
            // The full preferences path is noise; the "[+] loaded" prefix alone is enough
            // but the line also contains the full path, so skip it
            "preferences.json`",
            // Session log path line — replace with short form below
            "Session log /",
            // pm3 history notice — not useful in app context
            "No previous history could be loaded",
            "Output will be flushed after every print",
        ]
        return !noisy.contains { raw.contains($0) }
    }

    private func recordHistory(_ command: String) {
        if history.last != command { history.append(command) }
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        historyIndex = -1
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    private func writeToLog(_ line: TerminalLine) {
        let iso = ISO8601DateFormatter()
        let text = "[\(iso.string(from: line.timestamp))] \(line.raw)\n"
        sessionLogHandle?.write(text.data(using: .utf8) ?? Data())
    }
}
