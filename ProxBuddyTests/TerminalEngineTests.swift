import Testing
@testable import ProxBuddy

@MainActor
struct TerminalEngineTests {

    @Test func historyRecordsCommands() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        engine.sendCommand("hw status")
        #expect(engine.history == ["hf mf info", "hw status"])
    }

    @Test func historyDeduplicatesConsecutive() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        engine.sendCommand("hf mf info")
        #expect(engine.history.count == 1)
    }

    @Test func historyNavigationUp() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        engine.sendCommand("hw status")
        #expect(engine.historyUp() == "hw status")
        #expect(engine.historyUp() == "hf mf info")
    }

    @Test func historyNavigationDown() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        engine.sendCommand("hw status")
        _ = engine.historyUp()
        _ = engine.historyUp()
        #expect(engine.historyDown() == "hw status")
    }

    @Test func historyDownPastEndReturnsEmpty() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        _ = engine.historyUp()
        let result = engine.historyDown()
        #expect(result == "")
    }

    @Test func resetHistoryNavigation() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        _ = engine.historyUp()
        engine.resetHistoryNavigation()
        // After reset, up should go back to the last item
        #expect(engine.historyUp() == "hf mf info")
    }

    @Test func clearDisplay() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        engine.clearDisplay()
        // Lines contains only the input echo after sendCommand, then cleared
        #expect(engine.lines.isEmpty)
    }

    @Test func linesContainInputEcho() {
        let engine = TerminalEngine()
        engine.sendCommand("hf mf info")
        #expect(engine.lines.contains { $0.raw.contains("hf mf info") && $0.isInput })
    }

    @Test func captureIgnoresStartupBannerUntilPrompt() async {
        let engine = TerminalEngine()
        async let captured = engine.captureOutputSilent("help")
        for _ in 0..<50 {
            await Task.yield()
            if engine.isWaitingForPrompt { break }
        }

        engine.ingestOutput("[=] Using UART port tcp:192.168.1.62:7777")
        engine.ingestOutput("Client.... Iceman/master/v4.21611-1177-g83c3f81b1")
        engine.ingestOutput("pm3 --> ")
        for _ in 0..<50 {
            await Task.yield()
            if engine.isCollectingCapture { break }
        }

        engine.ingestOutput("hf             {high frequency commands...}")
        engine.ingestOutput("hw             {hardware commands...}")
        engine.ingestOutput("pm3 --> ")

        let lines = await captured
        #expect(lines.contains { $0.contains("high frequency") })
        #expect(lines.contains { $0.contains("hardware commands") })
        #expect(!lines.contains { $0.contains("Using UART") })
        #expect(!lines.contains { $0.contains("Iceman/master") })
    }

    @Test func captureAfterPromptCollectsOnlyCommandOutput() async {
        let engine = TerminalEngine()
        engine.ingestOutput("pm3 --> ")

        async let captured = engine.captureOutputSilent("help")
        for _ in 0..<50 {
            await Task.yield()
            if engine.isCollectingCapture { break }
        }

        engine.ingestOutput("lf             {low frequency commands...}")
        engine.ingestOutput("pm3 --> ")

        let lines = await captured
        #expect(lines == ["lf             {low frequency commands...}"])
    }
}
