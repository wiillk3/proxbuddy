import Testing
@testable import ProxBuddy

struct PM3SessionStatusTests {

    @Test @MainActor func devicesPageMirrorsRunnerIsRunning() {
        let session = PM3Session(label: "PM5 1")
        #expect(!session.isRunning)

        session.runner.isRunning = true
        #expect(session.isRunning)

        session.runner.isRunning = false
        #expect(!session.isRunning)
    }
}
