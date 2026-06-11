import Foundation

// Analyzes a batch of pm3 output lines (between prompts) and extracts a ScanRecord
// if a successful card read is detected.
enum ScanDetector {

    static func detect(lines: [String], command: String, timestamp: Date) -> ScanRecord? {
        let stripped = lines.map { stripAnsi($0) }

        // HF 14443-A / 14443-B — UID line present
        if stripped.contains(where: { $0.contains("[+]") && $0.contains("UID:") }) {
            return detectHF(stripped: stripped, command: command, timestamp: timestamp)
        }

        // LF EM4100
        if let line = stripped.first(where: {
            $0.contains("EM 410x ID:") || $0.contains("EM410x ID:") || $0.contains("Unique ID:")
        }) {
            return detectEM(line: line, command: command, timestamp: timestamp)
        }

        // LF HID / AWID / Indala
        if let line = stripped.first(where: {
            let up = $0.uppercased()
            return $0.contains("[+]") && (up.contains("HID") || up.contains("AWID") || up.contains("INDALA"))
        }) {
            return detectLFBadge(line: line, stripped: stripped, command: command, timestamp: timestamp)
        }

        // LF T55xx tag detected
        if stripped.contains(where: { $0.contains("[+]") && $0.contains("T55") }) {
            return detectT55(stripped: stripped, command: command, timestamp: timestamp)
        }

        return nil
    }

    // MARK: - HF 14443-A/B

    private static func detectHF(stripped: [String], command: String, timestamp: Date) -> ScanRecord {
        let uidLine = stripped.first { $0.contains("[+]") && $0.contains("UID:") } ?? ""
        let uid = extractValue(after: "UID:", in: uidLine)

        let sakLine = stripped.first { $0.contains("SAK:") } ?? ""
        let sakHex = extractValue(after: "SAK:", in: sakLine)
            .components(separatedBy: .whitespaces).first ?? ""
        let sakVal = UInt8(sakHex, radix: 16)

        let atqaLine = stripped.first { $0.contains("ATQA:") } ?? ""
        let atqa = extractValue(after: "ATQA:", in: atqaLine)

        let cardType = cardTypeFromSAK(sakVal)
        let protocol_ = command.lowercased().contains("14b") ? "HF 14443-B" : "HF 14443-A"

        var details = ""
        if !atqa.isEmpty  { details += "ATQA: \(atqa.trimmingCharacters(in: .whitespaces))" }
        if !sakHex.isEmpty { details += "  SAK: \(sakHex)" }

        return ScanRecord(timestamp: timestamp, command: command,
                          protocol_: protocol_, uid: uid, cardType: cardType,
                          details: details.trimmingCharacters(in: .whitespaces))
    }

    private static func cardTypeFromSAK(_ sak: UInt8?) -> String {
        switch sak {
        case 0x00: return "MIFARE Ultralight / NTAG"
        case 0x08, 0x28, 0x88, 0x98: return "MIFARE Classic 1K"
        case 0x09:  return "MIFARE Mini"
        case 0x18, 0x38: return "MIFARE Classic 4K"
        case 0x19:  return "MIFARE Classic 2K"
        case 0x10:  return "MIFARE Plus 2K (SL1)"
        case 0x11:  return "MIFARE Plus 4K (SL1)"
        case 0x20:  return "ISO 14443-4 / DESFire / MIFARE Plus (SL3)"
        case 0x24:  return "MIFARE DESFire"
        case 0x60:  return "iClass"
        case nil:   return "HF Card"
        default:    return String(format: "HF Card (SAK %02X)", sak!)
        }
    }

    // MARK: - LF EM4100

    private static func detectEM(line: String, command: String, timestamp: Date) -> ScanRecord {
        let uid = extractValue(after: "ID:", in: line)
        let details = uid.isEmpty ? line : ""
        return ScanRecord(timestamp: timestamp, command: command,
                          protocol_: "LF EM4100", uid: uid.isEmpty ? nil : uid,
                          cardType: "EM4100", details: details)
    }

    // MARK: - LF Badge (HID, AWID, Indala)

    private static func detectLFBadge(line: String, stripped: [String],
                                      command: String, timestamp: Date) -> ScanRecord {
        let upper = line.uppercased()
        let proto: String
        let cardType: String
        if upper.contains("AWID")   { proto = "LF AWID";   cardType = "AWID" }
        else if upper.contains("INDALA") { proto = "LF Indala"; cardType = "Indala" }
        else                         { proto = "LF HID";    cardType = "HID Prox" }

        // Try to extract FC and CN
        var details = ""
        if let fc = extractPattern(#"FC:\s*(\d+)"#, from: line)  { details += "FC: \(fc)  " }
        if let cn = extractPattern(#"CN:\s*(\d+)"#, from: line)  { details += "CN: \(cn)" }
        if details.isEmpty { details = line.trimmingCharacters(in: .whitespaces) }

        return ScanRecord(timestamp: timestamp, command: command,
                          protocol_: proto, uid: nil,
                          cardType: cardType, details: details.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - LF T55xx

    private static func detectT55(stripped: [String], command: String, timestamp: Date) -> ScanRecord {
        let detail = stripped.first { $0.contains("[+]") && $0.contains("T55") } ?? "T55xx detected"
        return ScanRecord(timestamp: timestamp, command: command,
                          protocol_: "LF T55xx", uid: nil,
                          cardType: "T55xx", details: detail.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Utilities

    private static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "",
                               options: .regularExpression)
    }

    private static func extractValue(after key: String, in line: String) -> String {
        guard let r = line.range(of: key) else { return "" }
        return String(line[r.upperBound...])
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: "\n\r")).first ?? ""
    }

    private static func extractPattern(_ pattern: String, from line: String) -> String? {
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(line[r])
        // Return the first capture group value (everything after the first space/colon)
        return match.components(separatedBy: CharacterSet(charactersIn: ": ")).last?.trimmingCharacters(in: .whitespaces)
    }
}
