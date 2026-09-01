import Foundation
import Testing
@testable import ProxBuddy

struct PM3ClientVersionTests {

    @Test func parsesGitVersionAndBuildTime() {
        let info = PM3ClientVersion.parse(from: versionBlob(
            git: "Iceman/master/v4.21611-1177-g83c3f81b1",
            built: "2026-09-01 04:41:16"
        ))
        #expect(info?.gitVersion == "Iceman/master/v4.21611-1177-g83c3f81b1")
        #expect(info?.buildTime == "2026-09-01 04:41:16")
        #expect(info?.summary == "Iceman/master/v4.21611-1177-g83c3f81b1\n2026-09-01 04:41:16")
    }

    @Test func parsesSuspectAndReleaseFallback() {
        let suspect = PM3ClientVersion.parse(from: versionBlob(
            git: "Iceman/master/v4.21611-1177-g83c3f81b1-suspect",
            built: "2026-09-01 04:39:42"
        ))
        #expect(suspect?.gitVersion == "Iceman/master/v4.21611-1177-g83c3f81b1-suspect")

        let fallback = PM3ClientVersion.parse(from: versionBlob(
            git: "Iceman/master/release (git)",
            built: "2026-01-01 00:00:00"
        ))
        #expect(fallback?.gitVersion == "Iceman/master/release (git)")
    }

    @Test func ignoresUnrelatedIcemanText() {
        var noise = Data("Access granted. Iceman approves\0".utf8)
        noise.append(versionBlob(
            git: "Iceman/master/v4.21611-1015-g41c180940",
            built: "2026-09-01 05:25:33"
        ))
        let info = PM3ClientVersion.parse(from: noise)
        #expect(info?.gitVersion == "Iceman/master/v4.21611-1015-g41c180940")
        #expect(info?.buildTime == "2026-09-01 05:25:33")
    }

    @Test func returnsNilWhenMissing() {
        #expect(PM3ClientVersion.parse(from: Data("no version here".utf8)) == nil)
    }

    private func versionBlob(git: String, built: String) -> Data {
        var data = Data("PAD".utf8)
        data.append(padded(git, PM3ClientVersion.gitVersionFieldSize))
        data.append(padded(built, PM3ClientVersion.buildTimeFieldSize))
        data.append(padded("43d401f5b", 10))
        return data
    }

    private func padded(_ s: String, _ size: Int) -> Data {
        var field = Data(count: size)
        let bytes = Array(s.utf8)
        precondition(bytes.count < size)
        field.replaceSubrange(0..<bytes.count, with: bytes)
        return field
    }
}
