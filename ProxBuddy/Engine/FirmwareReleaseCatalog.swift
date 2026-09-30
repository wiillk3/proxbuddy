import CryptoKit
import Foundation

/// Hosted PM5 firmware keyed to the bundled `libpm3client` git version.
/// `firmware/manifest.json` is published by `scripts/publish_firmware_release.sh`.
enum FirmwareReleaseCatalog {
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/wiillk3/proxbuddy/main/firmware/manifest.json")!
    static let defaultPlatform = "PM5"

    struct Manifest: Codable, Equatable, Sendable {
        let schema: Int
        let updated: String?
        let firmware: [Entry]
    }

    struct Entry: Codable, Equatable, Sendable {
        let clientGitVersion: String
        let clientCommit: String
        let platform: String
        let proxbuddyVersion: String
        let releaseTag: String
        let artifacts: Artifacts

        enum CodingKeys: String, CodingKey {
            case clientGitVersion = "client_git_version"
            case clientCommit = "client_commit"
            case platform
            case proxbuddyVersion = "proxbuddy_version"
            case releaseTag = "release_tag"
            case artifacts
        }
    }

    struct Artifacts: Codable, Equatable, Sendable {
        let fullimage: Artifact
        let bootrom: Artifact
    }

    struct Artifact: Codable, Equatable, Sendable {
        let url: String
        let sha256: String
        let size: Int

        var downloadURL: URL? { URL(string: url) }
    }

    enum Error: LocalizedError, Equatable {
        case noBundledClient
        case manifestUnavailable
        case noMatchingRelease(String)
        case invalidArtifact(String)
        case downloadFailed(String)
        case sizeMismatch(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .noBundledClient:
                return "Could not read the bundled pm3 client version"
            case .manifestUnavailable:
                return "Firmware manifest is unavailable"
            case .noMatchingRelease(let version):
                return "No hosted firmware for \(version). Flash from files built at the same Iceman commit."
            case .invalidArtifact(let name):
                return "Invalid release artifact: \(name)"
            case .downloadFailed(let detail):
                return "Download failed: \(detail)"
            case .sizeMismatch(let name):
                return "\(name) size did not match the manifest"
            case .checksumMismatch(let name):
                return "\(name) checksum did not match the manifest"
            }
        }
    }

    /// Load manifest from the network, falling back to the copy bundled in the app.
    static func loadManifest() async throws -> Manifest {
        if let remote = try? await fetchManifest(from: manifestURL) {
            return remote
        }
        if let bundled = bundledManifest() {
            return bundled
        }
        throw Error.manifestUnavailable
    }

    /// Entry for the bundled client on the given platform, if any.
    static func matchingEntry(
        in manifest: Manifest,
        clientGitVersion: String,
        platform: String = defaultPlatform
    ) -> Entry? {
        let wantCommit = PM3ClientVersion.commitHash(from: clientGitVersion)?.lowercased()
        for entry in manifest.firmware where entry.platform == platform {
            if entry.clientGitVersion == clientGitVersion {
                return entry
            }
            if let wantCommit {
                let have = entry.clientCommit.lowercased()
                if have == wantCommit || have.hasPrefix(wantCommit) || wantCommit.hasPrefix(have) {
                    return entry
                }
            }
        }
        return nil
    }

    /// Resolve the hosted release for this app build, if published.
    static func bundledRelease(platform: String = defaultPlatform) async throws -> Entry {
        guard let client = PM3ClientVersion.bundledInfo?.gitVersion else {
            throw Error.noBundledClient
        }
        let manifest = try await loadManifest()
        guard let entry = matchingEntry(in: manifest, clientGitVersion: client, platform: platform) else {
            throw Error.noMatchingRelease(client)
        }
        return entry
    }

    /// Download (or reuse cache) and verify release ELFs. Returns fullimage first, then bootrom when requested.
    static func prepareArtifacts(
        for entry: Entry,
        includeBootrom: Bool
    ) async throws -> [URL] {
        let cacheDir = releaseCacheDirectory(for: entry)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var urls: [URL] = []
        urls.append(try await materialize(
            entry.artifacts.fullimage,
            name: "fullimage.elf",
            in: cacheDir
        ))
        if includeBootrom {
            urls.append(try await materialize(
                entry.artifacts.bootrom,
                name: "bootrom.elf",
                in: cacheDir
            ))
        }
        return urls
    }

    // MARK: - Internals

    private static func fetchManifest(from url: URL) async throws -> Manifest {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Error.manifestUnavailable
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func bundledManifest() -> Manifest? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "firmware")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func releaseCacheDirectory(for entry: Entry) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let key = entry.clientCommit.lowercased()
        return docs.appendingPathComponent("pm3/firmware/releases/\(key)", isDirectory: true)
    }

    private static func materialize(_ artifact: Artifact, name: String, in dir: URL) async throws -> URL {
        guard let sourceURL = artifact.downloadURL else {
            throw Error.invalidArtifact(name)
        }
        let dest = dir.appendingPathComponent(name)
        if try cachedArtifactMatches(artifact, at: dest) {
            return dest
        }
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: dest)
        }

        let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Error.downloadFailed(name)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path(percentEncoded: false))
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if bytes != artifact.size {
            throw Error.sizeMismatch(name)
        }

        let digest = try sha256Hex(of: tempURL)
        if digest.lowercased() != artifact.sha256.lowercased() {
            throw Error.checksumMismatch(name)
        }

        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func cachedArtifactMatches(_ artifact: Artifact, at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if bytes != artifact.size { return false }
        let digest = try sha256Hex(of: url)
        return digest.lowercased() == artifact.sha256.lowercased()
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
