import Foundation

/// Frozen `help` / `--help` text so demo mode can drive the command browser
/// and builder without booting `libpm3client`.
enum DemoHelpCatalog {
    static let blockedMessage = "[!] Demo — UI only, nothing is sent"

    static func lines(for rawCommand: String) -> [String] {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return list("help") }

        let (base, isHelpProbe) = splitHelpProbe(trimmed)
        let key = base.lowercased()

        if isHelpProbe {
            return helpPages[key] ?? genericHelp(for: base)
        }
        if let listLines = lists[key] {
            return listLines
        }
        if let help = helpPages[key] {
            return help
        }
        return genericHelp(for: base)
    }

    private static func splitHelpProbe(_ command: String) -> (base: String, isHelp: Bool) {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last?.lowercased() else { return (command, false) }
        if last == "--help" || last == "-h" {
            return (parts.dropLast().joined(separator: " "), true)
        }
        return (command, false)
    }

    private static func entry(_ name: String, _ desc: String) -> String {
        let pad = max(2, 16 - name.count)
        return name + String(repeating: " ", count: pad) + desc
    }

    private static func genericHelp(for command: String) -> [String] {
        [
            "Usage: \(command) [options]",
            "Demo help only — connect a Proxmark5 to run this command.",
            "Options:",
            "    -h, --help                     This help",
        ]
    }

    private static let lists: [String: [String]] = [
        "help": [
            "-------- High Frequency --------",
            entry("hf", "{High frequency commands}"),
            "-------- Low Frequency --------",
            entry("lf", "{Low frequency commands}"),
            "-------- Hardware --------",
            entry("hw", "{Hardware commands}"),
            "-------- Data --------",
            entry("data", "{Plotting and data manipulation}"),
            "-------- Scripts --------",
            entry("script", "{Lua and Python scripts}"),
        ],
        "hf": [
            "-------- ISO14443A / MIFARE --------",
            entry("search", "Search for known HF tags"),
            entry("14a", "{ISO14443-A}"),
            entry("mf", "{MIFARE Classic}"),
            entry("mfu", "{MIFARE Ultralight}"),
            "-------- Other --------",
            entry("tune", "Measure HF antenna"),
        ],
        "hf mf": [
            entry("info", "Tag information"),
            entry("eload", "Load dump into emulator"),
            entry("sim", "Simulate MIFARE Classic"),
            entry("rdbl", "Read block"),
        ],
        "hf 14a": [
            entry("info", "ISO14443-A tag information"),
            entry("reader", "Act as ISO14443-A reader"),
        ],
        "hf mfu": [
            entry("info", "MIFARE Ultralight information"),
            entry("eload", "Load dump into emulator"),
        ],
        "lf": [
            entry("search", "Search for known LF tags"),
            entry("em", "{EM4xxx}"),
            entry("t55xx", "{T55xx}"),
        ],
        "lf em": [
            entry("read", "Read EM410x / EM4x05"),
            entry("sim", "Simulate EM410x"),
        ],
        "hw": [
            entry("status", "Hardware status"),
            entry("version", "Client and device versions"),
            entry("tune", "Measure antennas"),
        ],
        "data": [
            entry("plot", "Plot signal buffer (GUI)"),
            entry("print", "Print signal buffer samples"),
        ],
        "script": [
            entry("run", "Run a bundled Lua or Python script"),
            entry("list", "List scripts"),
        ],
    ]

    private static let helpPages: [String: [String]] = [
        "hf mf info": [
            "Usage: hf mf info [h]",
            "Read basic information from a MIFARE Classic tag.",
            "Options:",
            "    -h, --help                     This help",
            "    -f, --file <fn>                Dump file",
            "    -k, --key <hex>                Key (6 bytes)",
            "Examples/Notes:",
            "    hf mf info",
        ],
        "hf mf eload": [
            "Usage: hf mf eload [h] -f <fn>",
            "Load a dump into the device emulator memory.",
            "Options:",
            "    -h, --help                     This help",
            "    -f, --file <fn>                Dump file",
            "Examples/Notes:",
            "    hf mf eload -f hf-mf-deadbeef-dump",
        ],
        "hf mf sim": [
            "Usage: hf mf sim [h] [--1k|--4k]",
            "Simulate a MIFARE Classic tag from emulator memory.",
            "Options:",
            "    -h, --help                     This help",
            "    --1k                           1K card",
            "    --4k                           4K card",
            "    -u, --uid <hex>                UID to simulate",
            "Examples/Notes:",
            "    hf mf sim --1k",
        ],
        "hf search": [
            "Usage: hf search [h]",
            "Look for known high-frequency tags in the field.",
            "Options:",
            "    -h, --help                     This help",
        ],
        "hw status": [
            "Usage: hw status [h]",
            "Show hardware status (USB, battery, antennas).",
            "Options:",
            "    -h, --help                     This help",
        ],
        "hw version": [
            "Usage: hw version [h]",
            "Show client and firmware versions.",
            "Options:",
            "    -h, --help                     This help",
        ],
    ]

    private static func list(_ key: String) -> [String] {
        lists[key] ?? []
    }
}
