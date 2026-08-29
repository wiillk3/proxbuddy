#if targetEnvironment(simulator)
import Foundation

// In the simulator the process runs on the Mac and has direct access to
// /dev/tty.usbmodem* and the host filesystem. We skip the transport layer
// entirely and hand the macOS pm3 binary the real USB serial port.
enum SimulatorBoot {
    /// Set this to your host `proxmark3` binary if it is not in the search list below.
    /// `~` is the Mac home (`/Users/you`), not the Simulator container.
    /// Example: `"~/d3v/proxmark/proxmark3/client/proxmark3"`
    /// Leave empty to search ~/proxmark3, Homebrew, /usr/local/bin, then PATH.
    static let clientPath: String = "~/d3v/proxmark/proxmark3/client/proxmark3"

    static func pm3BinaryPath() -> String? {
        let override = clientPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            let expanded = expandHome(override)
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            NSLog("[ProxBuddy] SimulatorBoot.clientPath is not executable: \(expanded)")
            return nil
        }

        var seen = Set<String>()
        var candidates: [String] = [
            macHomeDirectory + "/proxmark3/client/proxmark3",
            "/opt/homebrew/bin/proxmark3",
            "/usr/local/bin/proxmark3",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/proxmark3" }
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

    /// Simulator `NSHomeDirectory()` is
    /// `/Users/<you>/Library/Developer/CoreSimulator/Devices/...`
    /// `getpwuid` is not reliable here; peel the Mac home off that path.
    private static var macHomeDirectory: String {
        let home = NSHomeDirectory()
        if let range = home.range(of: "/Library/Developer/CoreSimulator/") {
            return String(home[..<range.lowerBound])
        }
        return home
    }

    private static func expandHome(_ path: String) -> String {
        if path == "~" { return macHomeDirectory }
        if path.hasPrefix("~/") {
            return macHomeDirectory + "/" + path.dropFirst(2)
        }
        return path
    }
}
#endif
