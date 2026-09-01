import Foundation

/// Client identity baked into `libpm3client.dylib` by Iceman `mkversion.sh`.
/// Readable without launching the client or talking to hardware.
struct PM3ClientVersionInfo: Equatable, Sendable {
    let gitVersion: String
    let buildTime: String?

    var summary: String {
        if let buildTime, !buildTime.isEmpty {
            return "\(gitVersion)\n\(buildTime)"
        }
        return gitVersion
    }
}

enum PM3ClientVersion {
    /// `g_version_information.gitversion` is `char[50]`; `buildtime` follows it.
    static let gitVersionFieldSize = 50
    static let buildTimeFieldSize = 30

    static let bundledSummary: String = bundledInfo?.summary ?? "—"

    static var bundledInfo: PM3ClientVersionInfo? {
        guard let url = bundledDylibURL(),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return parse(from: data)
    }

    static func bundledDylibURL() -> URL? {
        Bundle.main.url(forResource: "libpm3client", withExtension: "dylib", subdirectory: "Frameworks")
            ?? Bundle.main.url(forResource: "libpm3client", withExtension: "dylib")
    }

    /// Pulls `Iceman/…` plus the compile timestamp from a libpm3 Mach-O.
    static func parse(from data: Data) -> PM3ClientVersionInfo? {
        let marker = Data("Iceman/".utf8)
        var searchStart = data.startIndex
        while let range = data[searchStart...].firstRange(of: marker) {
            let fieldStart = range.lowerBound
            guard let gitVersion = cString(in: data, at: fieldStart, maxLength: gitVersionFieldSize),
                  isGitVersion(gitVersion) else {
                searchStart = range.upperBound
                continue
            }
            let buildStart = fieldStart + gitVersionFieldSize
            let buildTime = cString(in: data, at: buildStart, maxLength: buildTimeFieldSize)
                .flatMap { isBuildTime($0) ? $0 : nil }
            return PM3ClientVersionInfo(gitVersion: gitVersion, buildTime: buildTime)
        }
        return nil
    }

    private static func isGitVersion(_ s: String) -> Bool {
        // mkversion.sh: "Iceman/<branch>/<describe>", e.g.
        // Iceman/master/v4.21611-1177-g83c3f81b1  or  Iceman/master/release (git)
        let parts = s.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "Iceman", !parts[1].isEmpty, !parts[2].isEmpty else {
            return false
        }
        return s.unicodeScalars.allSatisfy { CharacterSet.gitVersionAllowed.contains($0) }
    }

    private static func isBuildTime(_ s: String) -> Bool {
        // mkversion.sh: "YYYY-MM-DD HH:MM:SS"
        let chars = Array(s)
        guard chars.count == 19 else { return false }
        func digit(_ i: Int) -> Bool { chars[i].isNumber }
        return digit(0) && digit(1) && digit(2) && digit(3)
            && chars[4] == "-" && digit(5) && digit(6)
            && chars[7] == "-" && digit(8) && digit(9)
            && chars[10] == " " && digit(11) && digit(12)
            && chars[13] == ":" && digit(14) && digit(15)
            && chars[16] == ":" && digit(17) && digit(18)
    }

    private static func cString(in data: Data, at offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        let end = min(offset + maxLength, data.count)
        var i = offset
        while i < end, data[i] != 0 { i += 1 }
        guard i > offset else { return nil }
        return String(data: data[offset..<i], encoding: .ascii)
    }
}

private extension CharacterSet {
    static let gitVersionAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._- ()")
}
