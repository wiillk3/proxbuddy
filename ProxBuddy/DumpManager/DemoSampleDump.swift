import Foundation

/// One obviously fake MIFARE Classic 1K dump, written under tmp (not Documents/pm3).
enum DemoSampleDump {
    static let fileName = "hf-mf-DEADC0DE-dump.json"
    static let groupID = "hf-mf-DEADC0DE"
    static let uid = "DEADC0DE"

    static func dumpFile() throws -> DumpFile {
        let url = try writeIfNeeded()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return DumpFile(url: url, modDate: Date(), size: size)
    }

    private static func writeIfNeeded() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxbuddy-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try jsonData().write(to: url, options: .atomic)
        return url
    }

    static func jsonData() -> Data {
        var blocks: [String: String] = [:]
        for i in 0..<64 {
            blocks[String(i)] = hex(block(i))
        }
        let payload: [String: Any] = [
            "Created": "demo",
            "FileType": "mfc v2",
            "Card": [
                "UID": uid,
                "ATQA": "0004",
                "SAK": "08",
            ],
            "blocks": blocks,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    /// 4-byte UID DEADC0DE, BCC, SAK 08, ATQA 0400, then ASCII filler.
    private static func block(_ index: Int) -> [UInt8] {
        if index == 0 {
            let uid: [UInt8] = [0xDE, 0xAD, 0xC0, 0xDE]
            let bcc = uid.reduce(0 as UInt8, ^)
            return uid + [bcc, 0x08, 0x04, 0x00] + Array("DEMO".utf8) + [0, 0, 0, 0]
        }
        if index % 4 == 3 {
            return [
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                0xFF, 0x07, 0x80,
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            ]
        }
        if index == 4 {
            return Array("PROXBUDDY DEMO! ".utf8)
        }
        return Array(repeating: 0, count: 16)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
