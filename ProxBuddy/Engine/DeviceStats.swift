import Foundation

struct DeviceStatSection: Identifiable {
    let id: String
    let title: String
    var rows: [(key: String, value: String)]
    var extra: [String]
}

struct DeviceStatReport {
    var sections: [DeviceStatSection]

    func section(titled needle: String) -> DeviceStatSection? {
        sections.first { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    func value(section: String, key: String) -> String? {
        guard let sec = self.section(titled: section) else { return nil }
        return sec.rows.first { $0.key.localizedCaseInsensitiveContains(key) }?.value
    }

    var batterySoC: Int? {
        guard let raw = value(section: "Battery", key: "Battery SoC")
                ?? value(section: "Battery", key: "SoC") else { return nil }
        let digits = raw.prefix { $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }
}

enum DeviceStatParser {
    static func parse(_ lines: [String]) -> DeviceStatReport {
        var sections: [DeviceStatSection] = []
        var current = DeviceStatSection(id: "general", title: "General", rows: [], extra: [])

        func flush() {
            if !current.rows.isEmpty || !current.extra.isEmpty || current.title != "General" {
                sections.append(current)
            }
        }

        for raw in lines {
            let body = stripTag(ANSIParser.strip(raw))
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let indented = body.hasPrefix(" ") || body.hasPrefix("\t")
            if !indented, dottedKV(trimmed) == nil, !trimmed.contains("|"), !trimmed.hasPrefix("---") {
                flush()
                current = DeviceStatSection(id: trimmed, title: trimmed, rows: [], extra: [])
                continue
            }

            if let kv = dottedKV(trimmed) {
                current.rows.append(kv)
            } else {
                current.extra.append(trimmed)
            }
        }
        flush()
        return DeviceStatReport(sections: sections.filter { !$0.rows.isEmpty || !$0.extra.isEmpty })
    }

    private static func stripTag(_ s: String) -> String {
        var t = s
        if t.hasSuffix("\r") { t.removeLast() }
        for p in ["[#] ", "[#]", "[=] ", "[=]", "[+] ", "[+]", "[!] ", "[!]"] {
            if t.hasPrefix(p) {
                return String(t.dropFirst(p.count))
            }
        }
        return t
    }

    private static func dottedKV(_ line: String) -> (key: String, value: String)? {
        guard let range = line.range(of: #"\.{2,}"#, options: .regularExpression) else { return nil }
        let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let val = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, val.isEmpty ? "—" : val)
    }
}
