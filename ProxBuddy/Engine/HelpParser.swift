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
    let usage: String
    let options: [OptionDef]
    let examples: [String]
}

enum HelpParser {
    static func parse(_ lines: [String]) -> CommandHelp {
        var usage = ""
        var options: [OptionDef] = []
        var examples: [String] = []
        var section = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Native pm3: "usage:", "options:", "examples/notes"
            // Lua scripts: bare "Usage", "Arguments", "Example usage"
            if lower == "usage" || lower.hasPrefix("usage:") { section = "usage"; continue }
            if lower.hasPrefix("options:") || lower.hasPrefix("arguments") { section = "options"; continue }
            if lower.hasPrefix("example") || lower.hasPrefix("notes") { section = "examples"; continue }

            switch section {
            case "usage":
                if !trimmed.isEmpty { usage = trimmed }
            case "options":
                if let opt = parseLine(line) { options.append(opt) }
            case "examples":
                if !trimmed.isEmpty && !trimmed.hasSuffix(":") { examples.append(trimmed) }
            default: break
            }
        }

        // Lua scripts list bare flags ("-u  description") in Arguments without <arg> labels,
        // but the usage line does show which flags take values ("-u <uid>").
        // Promote those flags from .none to their proper arg type.
        if !options.isEmpty && !usage.isEmpty {
            options = applyUsageArgTypes(to: options, usageLine: usage)
        }

        return CommandHelp(usage: usage, options: options, examples: examples)
    }

    private static func applyUsageArgTypes(to options: [OptionDef], usageLine: String) -> [OptionDef] {
        // Parse usage line: every "-x <label>" pair means that flag takes an argument
        var usageArgs: [String: String] = [:]
        let tokens = usageLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for i in 0..<tokens.count {
            let tok = tokens[i]
            guard tok.hasPrefix("-"), i + 1 < tokens.count else { continue }
            let next = tokens[i + 1]
            if next.hasPrefix("<") {
                usageArgs[tok] = next.trimmingCharacters(in: CharacterSet(charactersIn: "<>()"))
            }
        }
        guard !usageArgs.isEmpty else { return options }

        return options.map { opt in
            guard opt.argType == .none else { return opt }
            for flag in opt.flags {
                if let label = usageArgs[flag] {
                    let argType: OptionDef.ArgType
                    switch label.lowercased() {
                    case "hex", "key", "passwd", "signature", "otp", "version", "pack", "gtu", "ats", "atqa", "sak":
                        argType = .hex
                    case "dec", "n", "num", "type":
                        argType = .decimal
                    case "fn", "file", "filename":
                        argType = .file
                    case "bin":
                        argType = .binary
                    default:
                        argType = .string
                    }
                    return OptionDef(flags: opt.flags, argType: argType, argLabel: label, description: opt.description)
                }
            }
            return opt
        }
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

        // Split flags from description at 3+ consecutive whitespace chars
        guard let sepRange = trimmed.range(of: #"\s{3,}"#, options: .regularExpression) else { return nil }
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

        let argType: OptionDef.ArgType
        switch argLabel?.lowercased() {
        case "hex":    argType = .hex
        case "dec":    argType = .decimal
        case "fn":     argType = .file
        case "bin":    argType = .binary
        case .some(_): argType = .string     // txt, format, name, uid, …
        case .none:    argType = .none
        }

        return OptionDef(flags: tokens, argType: argType, argLabel: argLabel, description: cleanDesc)
    }

    private static func parsePositional(_ trimmed: String) -> OptionDef? {
        guard let sepRange = trimmed.range(of: #"\s{3,}"#, options: .regularExpression) else { return nil }
        let flagStr = String(trimmed[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let description = String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !description.isEmpty else { return nil }
        let label = String(flagStr.dropFirst().dropLast()) // strip < >
        return OptionDef(flags: ["<\(label)>"], argType: .string, argLabel: label, description: description)
    }

    private static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
    }
}
