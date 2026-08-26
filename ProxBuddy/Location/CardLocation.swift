import Foundation
import CoreLocation

/// GPS location metadata attached to a card dump
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
        let base = dumpURL.deletingPathExtension()
        return base.appendingPathExtension("location.json")
    }

    static func load(for dumpURL: URL) -> CardLocation? {
        let url = sidecarURL(for: dumpURL)
        guard let data = try? Data(contentsOf: url),
              let loc = try? JSONDecoder().decode(CardLocation.self, from: data) else {
            return nil
        }
        return loc
    }

    func save(for dumpURL: URL) {
        let url = CardLocation.sidecarURL(for: dumpURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
