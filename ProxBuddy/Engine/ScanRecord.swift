import Foundation

struct ScanRecord: Identifiable, Codable {
    var id = UUID()
    var timestamp: Date
    var command: String
    var protocol_: String      // "HF 14443-A", "LF EM4100", etc.
    var uid: String?           // hex string; nil for some LF types
    var cardType: String       // "MIFARE Classic 1K", "EM4100", etc.
    var details: String        // SAK/ATQA for HF, FC/CN for HID, etc.

    // MARK: - Display helpers

    var protocolIsHF: Bool { protocol_.hasPrefix("HF") }

    var icon: String {
        switch cardType {
        case let t where t.contains("MIFARE") || t.contains("DESFire") || t.contains("Ultralight"):
            return "creditcard.fill"
        case let t where t.contains("iClass"):
            return "key.fill"
        case let t where t.contains("HID") || t.contains("AWID") || t.contains("Indala"):
            return "door.left.hand.closed"
        default:
            return "wave.3.right"
        }
    }

    var tintColor: String {   // stored as name so Codable stays simple
        switch cardType {
        case let t where t.contains("Classic"):  return "blue"
        case let t where t.contains("Ultralight") || t.contains("NTAG"): return "cyan"
        case let t where t.contains("DESFire"):  return "purple"
        case let t where t.contains("Plus"):     return "indigo"
        case let t where t.contains("iClass"):   return "orange"
        case let t where t.contains("HID"):      return "green"
        case let t where t.contains("EM"):       return "yellow"
        default:                                  return "gray"
        }
    }
}

// MARK: - Persistence

@MainActor
final class ScanHistoryStore: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []

    private let maxRecords = 200

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scan_history.json")
    }

    init() { load() }

    func add(_ record: ScanRecord) {
        // Deduplicate: don't record the same UID within 5 seconds of the last entry
        if let last = records.first,
           last.uid == record.uid && record.uid != nil,
           record.timestamp.timeIntervalSince(last.timestamp) < 5 { return }

        records.insert(record, at: 0)
        if records.count > maxRecords { records.removeLast() }
        save()
    }

    func delete(_ record: ScanRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
