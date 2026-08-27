import Foundation

// MARK: - Command list models (for the command browser)

struct CommandEntry: Identifiable {
    enum Kind { case group, leaf }
    let id = UUID()
    let name: String
    let description: String   // already cleaned (no { })
    let kind: Kind

    var isGroup: Bool { kind == .group }
}

struct BrowserSection: Identifiable {
    let id = UUID()
    let name: String          // "" if no section header
    var entries: [CommandEntry]
}

struct CommandPage {
    let sections: [BrowserSection]
    var isEmpty: Bool { sections.allSatisfy { $0.entries.isEmpty } }
}

enum CommandListParser {
    // Entries to hide from the browser (meta / destructive)
    private static let hidden: Set<String> = ["help", "quit", "exit", "clear", "hints", "rem", "msleep"]

    static func parse(_ lines: [String]) -> CommandPage {
        var sections: [BrowserSection] = []
        var current = BrowserSection(name: "", entries: [])

        for line in lines {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }

            if isSectionHeader(raw) {
                if !current.entries.isEmpty { sections.append(current) }
                current = BrowserSection(name: sectionName(raw), entries: [])
                continue
            }

            if let entry = parseEntry(raw), !hidden.contains(entry.name) {
                current.entries.append(entry)
            }
        }
        if !current.entries.isEmpty { sections.append(current) }

        return CommandPage(sections: sections)
    }

    private static func isSectionHeader(_ s: String) -> Bool {
        s.hasPrefix("---") || s.hasPrefix("===")
    }

    private static func sectionName(_ line: String) -> String {
        // "--------  ---- High Frequency ----"
        // Split on runs of dashes, trim, take first non-empty part
        line.components(separatedBy: CharacterSet(charactersIn: "-="))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func parseEntry(_ trimmed: String) -> CommandEntry? {
        // Skip separators and lines starting with special chars
        guard !trimmed.hasPrefix("-"), !trimmed.hasPrefix("["),
              !trimmed.hasPrefix("("), !trimmed.hasPrefix("/") else { return nil }

        // Must have 2+ spaces separating name from description
        guard let sep = trimmed.range(of: #"\s{2,}"#, options: .regularExpression) else { return nil }
        let name = String(trimmed[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
        var desc = String(trimmed[sep.upperBound...]).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, !desc.isEmpty else { return nil }
        // Name should be all word characters (letters, digits, -, _, .)
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.+*".contains($0) }) else { return nil }

        // Group detection: description wrapped in { }
        let isGroup = desc.hasPrefix("{")
        if isGroup {
            desc = desc.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            // Strip trailing "..." if present
            if desc.hasSuffix("...") { desc = String(desc.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        }

        return CommandEntry(name: name, description: desc, kind: isGroup ? .group : .leaf)
    }
}

struct OptionDef: Identifiable {
    enum ArgType {
        case none           // boolean flag  --mini, -v, -@
        case hex            // <hex>
        case decimal        // <dec>
        case file           // <fn>
        case binary         // <bin>  binary string e.g. 0001101
        case string         // <txt>, <format>, <name>, or any unknown <label>
    }

    let id = UUID()
    let flags: [String]     // all flag tokens, e.g. ["-k", "--key"] or ["-a"] or ["-@"]
    let argType: ArgType
    let argLabel: String?   // "hex", "dec", "fn", etc. — nil for boolean flags
    let description: String

    var primaryFlag: String { flags.first(where: { $0.hasPrefix("--") }) ?? flags.first ?? "" }
    var displayFlag: String { flags.joined(separator: ", ") }
    var isShortOnly: Bool   { !flags.contains(where: { $0.hasPrefix("--") }) }
}

struct CommandHelp {
    let summary: String
    let usage: String
    let options: [OptionDef]
    let examples: [String]

    var hasContent: Bool {
        !summary.isEmpty || !usage.isEmpty || !options.isEmpty || !examples.isEmpty
    }

    /// Prefer richer parses when probing `-h` vs `--help`.
    var rank: Int {
        options.count * 4
            + (usage.isEmpty ? 0 : 2)
            + (summary.isEmpty ? 0 : 1)
            + examples.count
    }
}

enum HelpParser {
    static func parse(_ lines: [String]) -> CommandHelp {
        var summaryLines: [String] = []
        var usage = ""
        var options: [OptionDef] = []
        var examples: [String] = []
        var section = ""

        for line in lines {
            let trimmed = stripAnsi(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isClientChrome(trimmed) else { continue }
            let lower = trimmed.lowercased()

            // Native pm3: "usage:", "options:", "examples/notes"
            // Lua scripts: bare "Usage", "Arguments", "Example usage"
            // Python: "Usage: foo <bar>" on one line, or argparse "usage:" / "options:"
            if lower == "usage" || lower.hasPrefix("usage:") {
                section = "usage"
                if lower.hasPrefix("usage:") {
                    let rest = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { usage = rest }
                }
                continue
            }
            if lower.hasPrefix("options:") || lower.hasPrefix("optional arguments")
                || lower == "arguments" || lower.hasPrefix("arguments:") {
                section = "options"
                continue
            }
            if lower.hasPrefix("example") || lower.hasPrefix("notes") {
                section = "examples"
                continue
            }

            switch section {
            case "usage":
                if usage.isEmpty {
                    usage = trimmed
                } else {
                    summaryLines.append(trimmed)
                }
            case "options":
                if let opt = parseLine(trimmed) { options.append(opt) }
            case "examples":
                if !trimmed.hasSuffix(":") { examples.append(trimmed) }
            default:
                summaryLines.append(trimmed)
            }
        }

        if !options.isEmpty && !usage.isEmpty {
            options = applyUsageArgTypes(to: options, usageLine: usage)
        }

        if options.isEmpty, !usage.isEmpty {
            options = positionalsFromUsage(usage)
        }

        let summary = summaryLines
            .filter { !$0.hasPrefix("script run") }
            .joined(separator: "\n")

        return CommandHelp(summary: summary, usage: usage, options: options, examples: examples)
    }

    private static func applyUsageArgTypes(to options: [OptionDef], usageLine: String) -> [OptionDef] {
        // Parse usage line: every "-x <label>" pair means that flag takes an argument
        var usageArgs: [String: String] = [:]
        let tokens = usageLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for i in 0..<tokens.count {
            let tok = tokens[i].trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            guard tok.hasPrefix("-"), i + 1 < tokens.count else { continue }
            let next = tokens[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            if next.hasPrefix("<") {
                usageArgs[tok] = next.trimmingCharacters(in: CharacterSet(charactersIn: "<>()"))
            }
        }
        guard !usageArgs.isEmpty else { return options }

        return options.map { opt in
            guard opt.argType == .none else { return opt }
            for flag in opt.flags {
                if let label = usageArgs[flag] {
                    return OptionDef(
                        flags: opt.flags,
                        argType: typeForArgLabel(label),
                        argLabel: label,
                        description: opt.description
                    )
                }
            }
            return opt
        }
    }

    /// Unattached `<label>` tokens in a usage line, so scripts like
    /// `xorcheck.py <ID Byte1> <ID Byte2> ... <LRC>` still get builder fields.
    private static func positionalsFromUsage(_ usageLine: String) -> [OptionDef] {
        let tokens = usageLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var labels: [String] = []
        var i = 0
        while i < tokens.count {
            let tok = tokens[i].trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            if tok.hasPrefix("-") {
                if i + 1 < tokens.count, tokens[i + 1].hasPrefix("<") { i += 2; continue }
                i += 1
                continue
            }
            if tok.hasPrefix("<"), tok.contains(">") {
                let inner = tok.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if !inner.isEmpty, inner != "...", inner.lowercased() != "params" {
                    labels.append(inner)
                }
            }
            i += 1
        }

        // Variadic / spacey labels collapse to one freeform field so the user
        // can type the rest of argv as shown in usage.
        let messy = labels.contains(where: { $0.contains(" ") }) || usageLine.contains("...")
        if messy, !labels.isEmpty {
            return [OptionDef(
                flags: ["<arguments>"],
                argType: .string,
                argLabel: "arguments",
                description: "Arguments as shown in usage"
            )]
        }

        return labels.map { label in
            OptionDef(
                flags: ["<\(label)>"],
                argType: typeForArgLabel(label),
                argLabel: label,
                description: label
            )
        }
    }

    private static func typeForArgLabel(_ label: String) -> OptionDef.ArgType {
        switch label.lowercased() {
        case "hex", "key", "passwd", "signature", "otp", "version", "pack", "gtu", "ats", "atqa", "sak":
            return .hex
        case "dec", "n", "num", "type":
            return .decimal
        case "fn", "file", "filename":
            return .file
        case "bin":
            return .binary
        default:
            return .string
        }
    }

    private static func isClientChrome(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("[") {
            let tag = trimmed.dropFirst().first
            if tag == "+" || tag == "=" || tag == "-" || tag == "!"
                || tag == "?" || tag == "/" || tag == "\\" || tag == "*" {
                return true
            }
        }
        let lower = trimmed.lowercased()
        return lower.hasPrefix("executing python")
            || lower.hasPrefix("executing lua")
            || lower.hasPrefix("finished ")
            || lower.hasPrefix("args ")
    }

    // MARK: - Line parser

    private static func parseLine(_ line: String) -> OptionDef? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Must start with - (flag) or < (positional arg like <filename>)
        let isFlag = trimmed.hasPrefix("-")
        let isPositional = trimmed.hasPrefix("<")
        guard isFlag || isPositional else { return nil }

        // Positional arg: `    <filename>    name of script to run`
        if isPositional {
            return parsePositional(trimmed)
        }

        // pm3 uses 3+ spaces; argparse / lua often use 2
        guard let sepRange = trimmed.range(of: #"\s{3,}"#, options: .regularExpression)
                ?? trimmed.range(of: #"\s{2,}"#, options: .regularExpression) else { return nil }
        var flagStr = String(trimmed[..<sepRange.lowerBound])
        let description = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !description.isEmpty else { return nil }

        // Strip ANSI color codes from description (some entries have them: `wiegand list`)
        let cleanDesc = stripAnsi(description)

        // Pull off trailing <arg>: could be <hex>, <dec>, <fn>, <txt>, <bin>, <format>, <name>, etc.
        var argLabel: String? = nil
        if let m = flagStr.range(of: #"\s+<(\w+)>$"#, options: .regularExpression) {
            let inner = String(flagStr[m]).trimmingCharacters(in: .whitespaces)
            argLabel = String(inner.dropFirst().dropLast())   // strip < >
            flagStr = String(flagStr[..<m.lowerBound])
        }

        // Parse individual flag tokens: "-k, --key"  or  "-a"  or  "-@"  or  "-*"
        // Split on comma + space, or just commas, keeping each token
        let tokens = flagStr
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && ($0.hasPrefix("-") || $0 == "*") }

        guard !tokens.isEmpty else { return nil }

        let resolved: OptionDef.ArgType = argLabel.map { typeForArgLabel($0) } ?? .none
        return OptionDef(flags: tokens, argType: resolved, argLabel: argLabel, description: cleanDesc)
    }

    private static func parsePositional(_ trimmed: String) -> OptionDef? {
        guard let sepRange = trimmed.range(of: #"\s{3,}"#, options: .regularExpression)
                ?? trimmed.range(of: #"\s{2,}"#, options: .regularExpression) else { return nil }
        let flagStr = String(trimmed[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let description = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !description.isEmpty else { return nil }
        let label = String(flagStr.dropFirst().dropLast()) // strip < >
        return OptionDef(flags: ["<\(label)>"], argType: .string, argLabel: label, description: description)
    }

    private static func stripAnsi(_ s: String) -> String {
        ANSIParser.strip(s)
    }
}
