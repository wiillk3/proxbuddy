#if targetEnvironment(simulator)
import Foundation

// In the simulator the process runs on the Mac and has direct access to
// /dev/tty.usbmodem* and the host filesystem. We skip the transport layer
// entirely and hand the macOS pm3 binary the real USB serial port.
//
// This lets you test the full pm3 client + TerminalEngine pipeline against
// real hardware without BLE or TCP.
enum SimulatorBoot {
    // Locations to check for the macOS pm3 binary, in priority order.
    private static let pm3Candidates = [
        // RRG repo build output (most likely for active development)
        "/Users/williamkellner/d3v/proxmark/proxmark3/client/proxmark3",
        // Homebrew
        "/opt/homebrew/bin/proxmark3",
        "/usr/local/bin/proxmark3",
    ]

    static func pm3BinaryPath() -> String? {
        pm3Candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    // Returns a human-readable description of what was found (or not).
    static func statusDescription() -> String {
        let bin = pm3BinaryPath() ?? "pm3 binary not found"
        let port = usbSerialPort() ?? "no USB serial port found"
        return "sim: \(bin.split(separator: "/").last ?? "?") · \(port)"
    }
}
#endif
