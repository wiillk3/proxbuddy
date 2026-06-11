import SwiftUI

struct ANSIParser {
    // pm3 output "default" is the terminal's white — reset (ESC[0m) restores this
    static let outputDefault = Color(white: 0.88)
    // Input lines (user commands echoed back) stay pm3-green
    static let inputDefault  = Color(red: 0.0, green: 0.8, blue: 0.2)

    static func parse(_ raw: String,
                      fontSize: CGFloat = 13,
                      defaultColor: Color = outputDefault) -> AttributedString {
        var result = AttributedString()
        var fg: Color = defaultColor
        var bold = false
        var dim = false
        var underline = false

        var s = raw[raw.startIndex...]

        while !s.isEmpty {
            if s.hasPrefix("\u{1B}[") {
                // Consume ESC [
                s = s[s.index(s.startIndex, offsetBy: 2)...]
                // Read everything up to and including the command byte
                var code = ""
                while let ch = s.first {
                    s = s[s.index(after: s.startIndex)...]
                    if ch.isLetter { applyCode(code, cmd: ch, fg: &fg, bold: &bold, dim: &dim, underline: &underline, defaultColor: defaultColor); break }
                    code.append(ch)
                }
            } else {
                let end = s.firstIndex(of: "\u{1B}") ?? s.endIndex
                let text = String(s[..<end])
                s = s[end...]
                guard !text.isEmpty else { continue }

                var seg = AttributedString(text)
                let weight: Font.Weight = bold ? .bold : (dim ? .thin : .regular)
                seg.font = .system(size: fontSize, weight: weight, design: .monospaced)
                seg.foregroundColor = dim ? fg.opacity(0.55) : fg
                if underline { seg.underlineStyle = .single }
                result.append(seg)
            }
        }
        return result
    }

    // MARK: - SGR code application

    private static func applyCode(_ code: String, cmd: Character,
                                  fg: inout Color, bold: inout Bool, dim: inout Bool,
                                  underline: inout Bool, defaultColor: Color) {
        guard cmd == "m" else { return }   // only handle SGR (m) sequences
        let parts = code.isEmpty ? ["0"] : code.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            switch Int(part) ?? 0 {
            // Attributes
            case 0:         fg = defaultColor; bold = false; dim = false; underline = false
            case 1:         bold = true;  dim = false
            case 2:         dim  = true;  bold = false
            case 4:         underline = true
            case 21, 22:    bold = false; dim = false
            case 24:        underline = false

            // Standard foreground colors (30–37)
            case 30:        fg = Color(white: 0.25)
            case 31:        fg = Color(red: 0.85, green: 0.25, blue: 0.25)
            case 32:        fg = Color(red: 0.20, green: 0.85, blue: 0.20)
            case 33:        fg = Color(red: 0.90, green: 0.85, blue: 0.20)
            case 34:        fg = Color(red: 0.35, green: 0.55, blue: 1.00)
            case 35:        fg = Color(red: 0.85, green: 0.35, blue: 0.85)
            case 36:        fg = Color(red: 0.25, green: 0.85, blue: 0.85)
            case 37:        fg = Color(white: 0.95)
            case 39:        fg = defaultColor

            // Bright foreground colors (90–97)
            case 90:        fg = Color(white: 0.55)
            case 91:        fg = Color(red: 1.00, green: 0.45, blue: 0.45)
            case 92:        fg = Color(red: 0.45, green: 1.00, blue: 0.45)
            case 93:        fg = Color(red: 1.00, green: 1.00, blue: 0.45)
            case 94:        fg = Color(red: 0.45, green: 0.65, blue: 1.00)
            case 95:        fg = Color(red: 1.00, green: 0.45, blue: 1.00)
            case 96:        fg = Color(red: 0.45, green: 1.00, blue: 1.00)
            case 97:        fg = .white

            // Background colors — ignore (we use a black terminal bg)
            case 40...49, 100...109: break

            default:        break
            }
        }
    }
}
