import Foundation
import CoreLocation

/// GPS location metadata attached to a card dump.
/// Stored as `<dump-basename>.location` next to the dump — not `.json`, which
/// the Files tab treats as a card dump and would clone forever.
struct CardLocation: Codable, Equatable, Identifiable {
    var id: String { "\(latitude),\(longitude)" }

    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let timestamp: Date
    let address: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var formattedCoordinates: String {
        let latDirection = latitude >= 0 ? "N" : "S"
        let lonDirection = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), latDirection, abs(longitude), lonDirection)
    }

    // MARK: - Sidecar IO

    static func sidecarURL(for dumpURL: URL) -> URL {
        dumpURL.deletingPathExtension().appendingPathExtension("location")
    }

    /// Old sidecars used `.location.json`, which the dump watcher then treated as a dump.
    static func legacySidecarURL(for dumpURL: URL) -> URL {
        dumpURL.deletingPathExtension().appendingPathExtension("location.json")
    }

    static func isSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "location"
            || name.hasSuffix(".location.json")
            || name.contains(".location.location")
    }

    static func load(for dumpURL: URL) -> CardLocation? {
        for url in [sidecarURL(for: dumpURL), legacySidecarURL(for: dumpURL)] {
            guard let data = try? Data(contentsOf: url),
                  let loc = try? decoder.decode(CardLocation.self, from: data) else {
                continue
            }
            return loc
        }
        return nil
    }

    func save(for dumpURL: URL) {
        let url = CardLocation.sidecarURL(for: dumpURL)
        guard let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: CardLocation.legacySidecarURL(for: dumpURL))
    }

    static func remove(for dumpURL: URL) {
        try? FileManager.default.removeItem(at: sidecarURL(for: dumpURL))
        try? FileManager.default.removeItem(at: legacySidecarURL(for: dumpURL))
    }

    /// Delete runaway `.location.json` clones (`foo.location.location.json`, …).
    static func purgeRunawaySidecars(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }
        for url in entries where isSidecar(url) {
            let name = url.lastPathComponent.lowercased()
            if name.contains(".location.location") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = fractionalISO.date(from: s) ?? plainISO.date(from: s) {
                    return date
                }
            }
            if let t = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: t)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported date")
        }
        return d
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
