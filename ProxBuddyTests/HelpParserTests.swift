import Testing
@testable import ProxBuddy

struct HelpParserTests {

    @Test func nativePm3Help() {
        let help = HelpParser.parse([
            "Usage: hf mf info [h]",
            "Options:",
            "    -h, --help                     This help",
            "    -f, --file <fn>                Dump file",
            "    -k, --key <hex>                Key (6 bytes)",
            "Examples/Notes:",
            "    hf mf info",
        ])
        #expect(help.usage == "hf mf info [h]")
        #expect(help.options.contains { $0.flags.contains("--file") && $0.argType == .file })
        #expect(help.options.contains { $0.flags.contains("--key") && $0.argType == .hex })
        #expect(help.examples.contains("hf mf info"))
    }

    @Test func luaScriptHelp() {
        let help = HelpParser.parse([
            "[+] executing lua /app/luascripts/data_hex_crc.lua",
            "[+] args '-h'",
            "Iceman",
            "v1.0.3",
            "This script calculates many checksums (CRC) over the provided hex input.",
            "Usage",
            "script run data_hex_crc [-d <hex>] [-w <width>]",
            "Arguments",
            "     -d       data in hex",
            "     -w       bitwidth of the CRC family",
            "Example usage",
            "    script run data_hex_crc -d 010203040506070809",
            "[+] finished data_hex_crc.lua",
        ])
        #expect(help.summary.contains("checksums"))
        #expect(help.usage.contains("data_hex_crc"))
        #expect(help.options.contains { $0.flags.contains("-d") && $0.argType == .hex })
        #expect(help.options.contains { $0.flags.contains("-w") })
        #expect(help.examples.contains { $0.contains("data_hex_crc") })
    }

    @Test func pythonXorcheckStyleHelp() {
        let help = HelpParser.parse([
            "[+] executing python /app/pyscripts/xorcheck.py",
            "[+] args '-h'",
            "xorcheck.py - Generate final byte for XOR LRC",
            "Usage: xorcheck.py <ID Byte1> <ID Byte2> ... <LRC>",
            "Specifying the bytes of a UID with a known LRC will find the last byte value",
            "Example:",
            "xorcheck.py 04 00 80 64 ba",
            "Should produce the output:",
            "Target (BA) requires final LRC XOR byte value: 5A",
            "[+] finished xorcheck.py",
        ])
        #expect(help.summary.contains("Generate final byte"))
        #expect(help.usage.contains("<LRC>"))
        #expect(help.options.count == 1)
        #expect(help.options[0].flags == ["<arguments>"])
        #expect(help.examples.contains { $0.contains("04 00 80 64 ba") })
        #expect(help.hasContent)
    }

    @Test func argparseHelp() {
        let help = HelpParser.parse([
            "usage: fm11rf08s_full.py [-h] [-n] [--fast]",
            "",
            "Full recovery of Fudan FM11RF08S cards.",
            "",
            "options:",
            "  -h, --help            show this help message and exit",
            "  -n, --nokeys          extract data even if keys are missing",
            "  --fast                use ecfill for faster card transactions",
        ])
        #expect(help.usage.contains("fm11rf08s_full.py"))
        #expect(help.summary.contains("Fudan"))
        #expect(help.options.contains { $0.flags.contains("--nokeys") && $0.argType == .none })
        #expect(help.options.contains { $0.flags.contains("--fast") })
    }
}
