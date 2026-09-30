import Foundation
import Testing
@testable import ProxBuddy

struct FirmwareReleaseCatalogTests {
    private let sampleManifest = """
    {
      "schema": 1,
      "updated": "2026-09-30T00:00:00Z",
      "firmware": [
        {
          "client_git_version": "Iceman/master/v4.21611-1177-g83c3f81b1",
          "client_commit": "83c3f81b1",
          "platform": "PM5",
          "proxbuddy_version": "1.3.0",
          "release_tag": "v1.3.0",
          "artifacts": {
            "fullimage": {
              "url": "https://example.com/fullimage.elf",
              "sha256": "aa",
              "size": 100
            },
            "bootrom": {
              "url": "https://example.com/bootrom.elf",
              "sha256": "bb",
              "size": 50
            }
          }
        }
      ]
    }
    """

    @Test func commitHashFromDescribe() {
        #expect(PM3ClientVersion.commitHash(from: "Iceman/master/v4.21611-1177-g83c3f81b1") == "83c3f81b1")
    }

    @Test func commitHashFromBareHash() {
        #expect(PM3ClientVersion.commitHash(from: "Iceman/master/83c3f81b1") == "83c3f81b1")
    }

    @Test func matchingEntryByGitVersion() throws {
        let manifest = try JSONDecoder().decode(FirmwareReleaseCatalog.Manifest.self, from: Data(sampleManifest.utf8))
        let entry = FirmwareReleaseCatalog.matchingEntry(
            in: manifest,
            clientGitVersion: "Iceman/master/v4.21611-1177-g83c3f81b1"
        )
        #expect(entry?.releaseTag == "v1.3.0")
    }

    @Test func matchingEntryByCommit() throws {
        let manifest = try JSONDecoder().decode(FirmwareReleaseCatalog.Manifest.self, from: Data(sampleManifest.utf8))
        let entry = FirmwareReleaseCatalog.matchingEntry(
            in: manifest,
            clientGitVersion: "Iceman/master/v4.21611-1177-gdeadbeef"
        )
        #expect(entry == nil)

        let byCommit = FirmwareReleaseCatalog.matchingEntry(
            in: manifest,
            clientGitVersion: "Iceman/master/v4.99999-1-g83c3f81b1"
        )
        #expect(byCommit?.clientCommit == "83c3f81b1")
    }

    @Test func noMatchForOtherPlatform() throws {
        let manifest = try JSONDecoder().decode(FirmwareReleaseCatalog.Manifest.self, from: Data(sampleManifest.utf8))
        let entry = FirmwareReleaseCatalog.matchingEntry(
            in: manifest,
            clientGitVersion: "Iceman/master/v4.21611-1177-g83c3f81b1",
            platform: "PM3RDV4"
        )
        #expect(entry == nil)
    }
}
