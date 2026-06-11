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
}
