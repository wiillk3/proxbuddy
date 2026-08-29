import Testing
@testable import ProxBuddy

struct PM3ClientStatusTests {

    @Test func quitAndFatalEndTheSession() {
        #expect(PM3ClientStatus.endsSession(PM3ClientStatus.quit))
        #expect(PM3ClientStatus.endsSession(PM3ClientStatus.fatal))
        #expect(PM3ClientStatus.quit == -100)
        #expect(PM3ClientStatus.fatal == -99)
    }

    @Test func successAndCommandErrorsKeepTheSession() {
        #expect(!PM3ClientStatus.endsSession(PM3ClientStatus.success))
        #expect(!PM3ClientStatus.endsSession(1))
        #expect(!PM3ClientStatus.endsSession(-1))
        #expect(!PM3ClientStatus.endsSession(-30))
        #expect(!PM3ClientStatus.endsSession(-98))
    }
}
