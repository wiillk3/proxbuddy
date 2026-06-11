import Testing
import Foundation
import SwiftUI
@testable import ProxBuddy

// Real pm3 output strings (captured from RDV4 hf mf info run)
struct ANSIParserTests {

    @Test func plainText() {
        let result = ANSIParser.parse("hello world")
        #expect(result.description == "hello world")
    }

    @Test func stripsEscapeCodes() {
        // pm3 outputs lines like: \u{1B}[32m[+]\u{1B}[0m UID: C5 EC A5 9A
        let raw = "\u{1B}[32m[+]\u{1B}[0m UID: C5 EC A5 9A"
        let text = ANSIParser.parse(raw).description
        #expect(text.contains("[+]"))
        #expect(text.contains("UID: C5 EC A5 9A"))
        #expect(!text.contains("\u{1B}"))
    }

    @Test func handlesResetCode() {
        let raw = "\u{1B}[31mred\u{1B}[0m normal"
        let result = ANSIParser.parse(raw)
        // Should not crash and should contain both words
        let text = result.description
        #expect(text.contains("red"))
        #expect(text.contains("normal"))
    }

    @Test func handlesEmptyString() {
        let result = ANSIParser.parse("")
        #expect(result.description == "")
    }

    @Test func handlesBoldCode() {
        let raw = "\u{1B}[1mbold text\u{1B}[0m"
        let text = ANSIParser.parse(raw).description
        #expect(text.contains("bold text"))
    }

    @Test func multipleSegments() {
        // Typical pm3 section header
        let raw = "\u{1B}[36m[=]\u{1B}[0m --- ISO14443-a Information ---"
        let text = ANSIParser.parse(raw).description
        #expect(text.contains("[=]"))
        #expect(text.contains("ISO14443-a"))
    }

    @Test func realHfMfInfoLine() {
        // Exact line from the RDV4 hf mf info output (green [+] prefix)
        let raw = "\u{1B}[32m[+]\u{1B}[0m  UID: C5 EC A5 9A "
        let text = ANSIParser.parse(raw).description
        #expect(text.contains("C5 EC A5 9A"))
    }
}
