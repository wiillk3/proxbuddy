import SwiftUI

// MARK: - Card family

enum CardFamily: Hashable {
    case mifareClassic, mifareUltralight, mifareDesfire, mifareplus
    case iclass, iso14443b
    case em, hid, awid, indala
    case unknown

    init(filename: String) {
        let s = filename.lowercased()
        if      s.hasPrefix("hf-mfdes")  { self = .mifareDesfire }
        else if s.hasPrefix("hf-mfp")    { self = .mifareplus }
        else if s.hasPrefix("hf-mfu")    { self = .mifareUltralight }
        else if s.hasPrefix("hf-mf")     { self = .mifareClassic }
        else if s.hasPrefix("hf-iclass") { self = .iclass }
        else if s.hasPrefix("hf-14b")    { self = .iso14443b }
        else if s.hasPrefix("lf-hid")    { self = .hid }
        else if s.hasPrefix("lf-awid")   { self = .awid }
        else if s.hasPrefix("lf-indala") { self = .indala }
        else if s.hasPrefix("lf-em")     { self = .em }
        else                             { self = .unknown }
    }

    var displayName: String {
        switch self {
        case .mifareClassic:    return "MIFARE Classic"
        case .mifareUltralight: return "MIFARE Ultralight"
        case .mifareDesfire:    return "MIFARE DESFire"
        case .mifareplus:       return "MIFARE Plus"
        case .iclass:           return "iClass"
        case .iso14443b:        return "ISO 14443-B"
        case .hid:              return "HID Prox"
        case .awid:             return "AWID"
        case .indala:           return "Indala"
        case .em:               return "EM4100"
        case .unknown:          return "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .mifareClassic, .mifareUltralight, .mifareDesfire, .mifareplus:
            return "creditcard.fill"
        case .iclass:           return "key.fill"
        case .hid, .awid:       return "door.left.hand.closed"
        case .em, .indala:      return "wave.3.right"
        case .iso14443b:        return "creditcard"
        case .unknown:          return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .mifareClassic:    return .blue
        case .mifareUltralight: return .cyan
        case .mifareDesfire:    return .purple
        case .mifareplus:       return .indigo
        case .iclass:           return .orange
        case .hid, .awid:       return .green
        case .em, .indala:      return .yellow
        default:                return .gray
        }
    }

    /// pm3 command to load this dump into the emulator. nil if unsupported.
    func eloadCommand(file: String) -> String? {
        switch self {
        case .mifareClassic:    return "hf mf eload -f \(file)"
        case .mifareUltralight: return "hf mfu eload -f \(file)"
        case .iclass:           return "hf iclass eload -f \(file)"
        default:                return nil
        }
    }

    func simCommand(uid: String?, is4K: Bool) -> String? {
        switch self {
        case .mifareClassic:
            var cmd = "hf mf sim --\(is4K ? "4k" : "1k")"
            if let u = uid { cmd += " -u \(u.replacingOccurrences(of: " ", with: ""))" }
            return cmd
        case .mifareUltralight:
            var cmd = "hf mfu sim -t 2"
            if let u = uid { cmd += " -u \(u.replacingOccurrences(of: " ", with: ""))" }
            return cmd
        case .iclass:           return "hf iclass sim -t 3"
        default:                return nil
        }
    }

    var eviewCommand: String? {
        switch self {
        case .mifareClassic:    return "hf mf eview"
        case .mifareUltralight: return "hf mfu eview"
        default:                return nil
        }
    }
}

// MARK: - DumpFile

struct DumpFile: Identifiable {
    let id = UUID()
    let url: URL
    let modDate: Date
    let size: Int64
    let family: CardFamily
    let uid: String?   // e.g. "C5 EC A5 9A" (spaced)

    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var fileName: String { url.lastPathComponent }

    init(url: URL, modDate: Date, size: Int64) {
        self.url = url
        self.modDate = modDate
        self.size = size
        let name = url.deletingPathExtension().lastPathComponent
        self.family = CardFamily(filename: name)
        self.uid = DumpFile.extractUID(from: name)
    }

    /// Extract hex UID from filename segment, e.g. "hf-mf-C5ECA59A-dump" → "C5 EC A5 9A"
    static func extractUID(from name: String) -> String? {
        for part in name.components(separatedBy: "-") {
            let up = part.uppercased()
            guard (8...20).contains(up.count),
                  up.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { continue }
            return stride(from: 0, to: up.count, by: 2)
                .map { i -> String in
                    let s = up.index(up.startIndex, offsetBy: i)
                    let e = up.index(s, offsetBy: min(2, up.count - i))
                    return String(up[s..<e])
                }
                .joined(separator: " ")
        }
        return nil
    }

    var sizeString: String {
        if size < 1024 { return "\(size) B" }
        return String(format: "%.1f KB", Double(size) / 1024)
    }

    /// e.g. "hf-mf-C5ECA59A-dump" or "hf-mf-C5ECA59A-key" → "hf-mf-C5ECA59A"
    var groupKey: String {
        var name = baseName
        for suffix in ["-dump", "-key", "-trace", "-nonces", "-rawlf", "-rawss"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
        }
        return name
    }

    /// Whether this is a key-only file (no block data)
    var isKeyFile: Bool { baseName.hasSuffix("-key") }
}

// MARK: - DumpGroup

/// One logical card dump — potentially represented by multiple files (.json, .bin, -key.bin)
struct DumpGroup: Identifiable {
    let id: String          // groupKey, e.g. "hf-mf-C5ECA59A"
    let family: CardFamily
    let uid: String?
    var files: [DumpFile]

    var location: CardLocation? {
        guard let file = primaryFile else { return nil }
        return CardLocation.load(for: file.url)
    }

    var latestDate: Date { files.map(\.modDate).max() ?? .distantPast }

    /// Best file for parsing: json > eml > bin dump (not key-only)
    var primaryFile: DumpFile? {
        let dumps = files.filter { !$0.isKeyFile }
        return dumps.first(where: { $0.ext == "json" })
            ?? dumps.first(where: { $0.ext == "eml" })
            ?? dumps.first(where: { $0.ext == "bin" })
    }

    var keyFile: DumpFile? { files.first(where: { $0.isKeyFile }) }

    var formatPills: [String] {
        var out: [String] = []
        if files.contains(where: { $0.ext == "json" }) { out.append("JSON") }
        if files.contains(where: { $0.ext == "eml"  }) { out.append("EML") }
        if files.contains(where: { !$0.isKeyFile && $0.ext == "bin" }) { out.append("BIN") }
        if keyFile != nil { out.append("KEY") }
        return out
    }

    static func group(_ files: [DumpFile]) -> [DumpGroup] {
        var map: [String: [DumpFile]] = [:]
        for f in files { map[f.groupKey, default: []].append(f) }
        return map.map { key, fs in
            let sorted = fs.sorted { $0.modDate > $1.modDate }
            return DumpGroup(id: key, family: sorted[0].family, uid: sorted[0].uid, files: sorted)
        }
        .sorted { $0.latestDate > $1.latestDate }
    }
}

// MARK: - MIFARE Classic parsed dump

struct MFBlock: Identifiable {
    let id: Int
    let data: [UInt8]

    var hex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    var ascii: String {
        String(data.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : Character(".") })
    }
    var isBlank: Bool { data.allSatisfy { $0 == 0xFF } || data.allSatisfy { $0 == 0 } }
}

struct MFSector: Identifiable {
    let id: Int
    let blocks: [MFBlock]

    var trailerBlock: MFBlock { blocks.last! }
    var keyA: String { trailerBlock.data[0..<6].map { String(format: "%02X", $0) }.joined() }
    var keyB: String { trailerBlock.data[10..<16].map { String(format: "%02X", $0) }.joined() }

    enum KeyStatus { case defaultKey, blank, custom }

    var keyAStatus: KeyStatus { keyStatus(keyA) }
    var keyBStatus: KeyStatus { keyStatus(keyB) }

    private func keyStatus(_ key: String) -> KeyStatus {
        if key == "000000000000" { return .blank }
        if MFSector.wellKnownKeys.contains(key) { return .defaultKey }
        return .custom
    }

    static let wellKnownKeys: Set<String> = [
        "FFFFFFFFFFFF", "A0A1A2A3A4A5", "B0B1B2B3B4B5",
        "AABBCCDDEEFF", "000000000000", "D3F7D3F7D3F7",
        "4B0B20107CCB", "1A982C7E459A", "AA0720018103",
        "2A2C13CC242A",
    ]
}

struct ParsedMFDump {
    let uid: String
    let atqa: String
    let sak: String
    let sectors: [MFSector]

    var blockCount: Int { sectors.reduce(0) { $0 + $1.blocks.count } }
    var cardLabel: String {
        switch blockCount {
        case 20:  return "MIFARE Mini (320B)"
        case 64:  return "MIFARE Classic 1K"
        case 128: return "MIFARE Classic 2K"
        case 256: return "MIFARE Classic 4K"
        default:  return "MIFARE Classic (\(blockCount * 16)B)"
        }
    }

    // MARK: Parsers

    static func from(url: URL) -> ParsedMFDump? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        switch url.pathExtension.lowercased() {
        case "json": return fromJSON(data)
        case "eml":  return fromEML(data)
        case "bin":  return fromBinary(data)
        default:     return nil
        }
    }

    static func fromJSON(_ data: Data) -> ParsedMFDump? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let card  = json["Card"] as? [String: Any] ?? [:]
        let uid   = card["UID"]  as? String ?? "?"
        let atqa  = card["ATQA"] as? String ?? "?"
        let sak   = card["SAK"]  as? String ?? "?"
        let rawBlocks = (json["blocks"] as? [String: String]) ?? [:]

        var blockMap: [Int: [UInt8]] = [:]
        for (key, hex) in rawBlocks {
            guard let n = Int(key) else { continue }
            let bytes = parseHex(hex)
            if bytes.count == 16 { blockMap[n] = bytes }
        }
        return buildSectors(uid: uid, atqa: atqa, sak: sak, blockMap: blockMap)
    }

    static func fromEML(_ data: Data) -> ParsedMFDump? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var blockMap: [Int: [UInt8]] = [:]
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            let hex = line.trimmingCharacters(in: .whitespaces)
            let bytes = parseHex(hex)
            if bytes.count == 16 { blockMap[i] = bytes }
        }
        let uid = uidFromBlock0(blockMap[0])
        return buildSectors(uid: uid, atqa: "?", sak: "?", blockMap: blockMap)
    }

    static func fromBinary(_ data: Data) -> ParsedMFDump? {
        guard data.count % 16 == 0 else { return nil }
        var blockMap: [Int: [UInt8]] = [:]
        for i in 0..<(data.count / 16) {
            blockMap[i] = Array(data[(i*16)..<(i*16+16)])
        }
        let uid = uidFromBlock0(blockMap[0])
        return buildSectors(uid: uid, atqa: "?", sak: "?", blockMap: blockMap)
    }

    // MARK: Helpers

    private static func buildSectors(uid: String, atqa: String, sak: String,
                                     blockMap: [Int: [UInt8]]) -> ParsedMFDump {
        let total = (blockMap.keys.max() ?? 0) + 1

        // 4K layout: sectors 0-31 = 4 blocks, sectors 32-39 = 16 blocks
        var sectors: [MFSector] = []
        if total > 128 {
            for s in 0..<32 {
                sectors.append(sector(s, base: s*4, size: 4, from: blockMap))
            }
            for s in 0..<8 {
                sectors.append(sector(32+s, base: 128+s*16, size: 16, from: blockMap))
            }
        } else {
            let count = max(16, (total + 3) / 4)
            for s in 0..<count {
                sectors.append(sector(s, base: s*4, size: 4, from: blockMap))
            }
        }
        return ParsedMFDump(uid: uid, atqa: atqa, sak: sak, sectors: sectors)
    }

    private static func sector(_ id: Int, base: Int, size: Int,
                                from blockMap: [Int: [UInt8]]) -> MFSector {
        let blocks = (0..<size).map { i -> MFBlock in
            let n = base + i
            return MFBlock(id: n, data: blockMap[n] ?? Array(repeating: 0, count: 16))
        }
        return MFSector(id: id, blocks: blocks)
    }

    private static func uidFromBlock0(_ block: [UInt8]?) -> String {
        guard let b = block else { return "?" }
        return b[0..<4].map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func parseHex(_ hex: String) -> [UInt8] {
        let clean = hex.filter { "0123456789ABCDEFabcdef".contains($0) }
        guard clean.count % 2 == 0 else { return [] }
        return stride(from: 0, to: clean.count, by: 2).compactMap { i -> UInt8? in
            let s = clean.index(clean.startIndex, offsetBy: i)
            let e = clean.index(s, offsetBy: 2)
            return UInt8(clean[s..<e], radix: 16)
        }
    }
}

// MARK: - PM3HOME setup

enum PM3HomeSetup {
    /// Creates Documents/pm3/, writes pm3 preferences so files land there, returns the path.
    static func prepare(binaryPath: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pm3Dir = docs.appendingPathComponent("pm3")
        let fm = FileManager.default
        try? fm.createDirectory(at: pm3Dir, withIntermediateDirectories: true)

        #if targetEnvironment(simulator)
        // Symlink resource dirs from the host pm3 client directory so pm3 finds them
        let clientDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        let resources = ["luascripts", "dictionaries", "cmdscripts", "lualibs",
                         "pyscripts", "aidlist.json", "mfc_default_keys.dic"]
        for name in resources {
            let src = clientDir.appendingPathComponent(name).path
            let dst = pm3Dir.appendingPathComponent(name).path
            guard fm.fileExists(atPath: src) else { continue }
            if fm.fileExists(atPath: dst) { continue }
            try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
        }
        #else
        // Copy bundle resources on first launch
        let sentinel = pm3Dir.appendingPathComponent(".resources_installed")
        if !fm.fileExists(atPath: sentinel.path) {
            for name in ["luascripts", "dictionaries", "cmdscripts", "lualibs", "pyscripts"] {
                if let src = Bundle.main.url(forResource: name, withExtension: nil) {
                    let dst = pm3Dir.appendingPathComponent(name)
                    if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
                }
            }
            fm.createFile(atPath: sentinel.path, contents: nil)
        }
        #endif

        // Write pm3 preferences into $HOME/.proxmark3/preferences.json so pm3 saves
        // files to Documents/pm3/ instead of its default $HOME directory.
        // pm3 uses getenv("HOME") for this lookup — we pass HOME as the Documents directory,
        // so this file lands exactly where pm3 will look for it.
        writePreferences(savePath: pm3Dir.path)

        return pm3Dir.path
    }

    private static func writePreferences(savePath: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pm3PrefDir = docs.appendingPathComponent(".proxmark3")
        let prefFile = pm3PrefDir.appendingPathComponent("preferences.json")
        let fm = FileManager.default
        try? fm.createDirectory(at: pm3PrefDir, withIntermediateDirectories: true)

        var prefs: [String: Any]
        if let data = fm.contents(atPath: prefFile.path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // File already exists. If the save path is already correct, leave it completely
            // alone so pm3 can freely manage its own preferences without us racing it.
            if (existing["file.default.savepath"] as? String) == savePath &&
               (existing["file.default.dumppath"] as? String) == savePath {
                return
            }
            prefs = existing
        } else {
            // Fresh container — seed sensible defaults so the user gets colors etc. on first run
            prefs = [
                "Created":           "proxmark3",
                "FileType":          "settings",
                "os.supports.colors": true,
                "show.hints":         true,
                "output.dense":       false,
            ]
        }

        prefs["file.default.savepath"] = savePath
        prefs["file.default.dumppath"] = savePath

        if let data = try? JSONSerialization.data(withJSONObject: prefs,
                                                   options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: prefFile)
        }
    }

    static var documentsPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pm3").path
    }
}
