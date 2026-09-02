import Testing
@testable import ProxBuddy

struct OutputLineSplitterTests {

    @Test func committedNewlines() {
        var s = OutputLineSplitter()
        #expect(s.push("hello\nworld\n") == ["hello", "world"])
    }

    @Test func crlfIsAPlainNewline() {
        var s = OutputLineSplitter()
        #expect(s.push("hello\r\n") == ["hello"])
    }

    @Test func crThenNewlineAcrossChunks() {
        var s = OutputLineSplitter()
        #expect(s.push("hello\r").isEmpty)
        #expect(s.push("\n") == ["hello"])
    }

    @Test func promptWithoutNewline() {
        var s = OutputLineSplitter()
        #expect(s.push("pm3 --> ") == ["pm3 --> "])
    }

    @Test func inplaceSearchFlushesLiveText() {
        var s = OutputLineSplitter()
        let first = s.push("\r 🕚  Searching for TEXKOM tag...")
        #expect(first.count == 1)
        #expect(first[0].hasPrefix("\r"))
        #expect(first[0].contains("TEXKOM"))

        // PROMPT_CLEARLINE then the next protocol — search text should win.
        #expect(s.push("\r 🕛                                           \r").isEmpty)
        let second = s.push("\r 🕐  Searching for Fuji/Xerox tag...")
        #expect(second.count == 1)
        #expect(second[0].contains("Fuji/Xerox"))
        #expect(second[0].hasPrefix("\r"))
    }

    @Test func mixBarAfterCSIClearIsLive() {
        var s = OutputLineSplitter()
        // hf tune --mix: backspace + ESC[2K + CR + bar (no trailing newline)
        let chunk = "\u{8}\u{1B}[2K\r[=] ████ [ 100 mV / 0 V / 0 Vmax ]"
        let out = s.push(chunk)
        #expect(out.count == 1)
        #expect(out[0].hasPrefix("\r"))
        #expect(out[0].contains("100 mV"))
        #expect(out[0].contains("████"))
        #expect(!out[0].contains("\u{1B}[2K"))
        #expect(!out[0].contains("\u{8}"))

        let next = s.push("\u{8}\u{1B}[2K\r[=] ████████ [ 8500 mV /  8 V /  8 Vmax ]")
        #expect(next.count == 1)
        #expect(next[0].contains("8500 mV"))
        #expect(!next[0].contains("100 mV"))
    }

    @Test func crThenNewlineTakesTextAfterCR() {
        var s = OutputLineSplitter()
        #expect(s.push("foo\rbar\n") == ["bar"])
    }
}
