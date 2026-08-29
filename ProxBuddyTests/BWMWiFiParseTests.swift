import Testing
@testable import ProxBuddy

struct BWMWiFiParseTests {

    @Test func parsesConnectString() {
        let lines = [
            "[+] BWM on WiFi at 192.168.1.77",
            "[?] Connect with: pm3 -p tcp:192.168.1.77:7777",
        ]
        let parsed = BWMWiFiParse.endpoint(from: lines)
        #expect(parsed?.host == "192.168.1.77")
        #expect(parsed?.port == 7777)
    }

    @Test func parsesCustomPort() {
        let lines = ["[?] Connect with: pm3 -p tcp:10.0.0.8:9000"]
        let parsed = BWMWiFiParse.endpoint(from: lines)
        #expect(parsed?.host == "10.0.0.8")
        #expect(parsed?.port == 9000)
    }

    @Test func parsesHostLineWithoutConnectString() {
        let parsed = BWMWiFiParse.endpoint(from: ["[+] BWM on WiFi at 192.168.1.77"])
        #expect(parsed?.host == "192.168.1.77")
        #expect(parsed?.port == 7777)
    }

    @Test func returnsNilWhenMissing() {
        #expect(BWMWiFiParse.endpoint(from: ["failed to join"]) == nil)
    }
}
