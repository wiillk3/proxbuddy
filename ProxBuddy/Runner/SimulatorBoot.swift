#if targetEnvironment(simulator)
import Foundation

// In the simulator the process runs on the Mac and has direct access to
// /dev/tty.usbmodem* and the host filesystem. We skip the transport layer
// entirely and hand the macOS pm3 binary the real USB serial port.
enum SimulatorBoot {
    static func pm3BinaryPath() -> String? {
        var seen = Set<String>()
        var candidates: [String] = [
            NSHomeDirectory() + "/proxmark3/client/proxmark3",
            "/opt/homebrew/bin/proxmark3",
            "/usr/local/bin/proxmark3",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/proxmark3" }
        }
        if let resolved = which("proxmark3") {
            candidates.append(resolved)
        }
        return candidates.first { path in
            seen.insert(path).inserted
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func usbSerialPort() -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return nil
        }
        return entries
            .filter { $0.hasPrefix("tty.usbmodem") || $0.hasPrefix("tty.usbserial") }
            .sorted()
            .map { "/dev/\($0)" }
            .first
    }

    static func statusDescription() -> String {
        let bin = pm3BinaryPath() ?? "pm3 binary not found"
        let port = usbSerialPort() ?? "no USB serial port found"
        return "sim: \(bin.split(separator: "/").last ?? "?") · \(port)"
    }

    /// Xcode's Simulator PATH often omits Homebrew; a login shell still sees it.
    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0,
              let data = try? out.fileHandleForReading.readToEnd(),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}
#endif
