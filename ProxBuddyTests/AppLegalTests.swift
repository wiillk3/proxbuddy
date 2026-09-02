import Foundation
import Testing
@testable import ProxBuddy

struct AppLegalTests {

    @Test func sourceAndSupportPointAtThePublicRepo() {
        #expect(AppLegal.sourceURL.host == "github.com")
        #expect(AppLegal.sourceURL.path == "/spot-rfid/proxbuddy")
        #expect(AppLegal.supportURL.path == "/spot-rfid/proxbuddy/issues")
        #expect(AppLegal.privacyURL.path.hasSuffix("/PRIVACY.md"))
    }

    @Test func documentsCoverRequiredLicenseTexts() {
        let ids = Set(AppLegal.Document.allCases.map(\.rawValue))
        #expect(ids == ["PRIVACY", "GPL-3.0", "GPL-2.0", "Apache-2.0"])
    }

    @Test func privacyPolicyTextIsNonEmpty() {
        let text = AppLegal.text(for: .privacyPolicy)
        #expect(text.contains("ProxBuddy"))
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func warrantyNoticeIsPresent() {
        #expect(AppLegal.warrantyLine.lowercased().contains("no warranty"))
        #expect(AppLegal.copyrightLine.contains("2026"))
    }
}
