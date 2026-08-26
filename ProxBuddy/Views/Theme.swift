import SwiftUI

extension Color {
    // Standard hacker neon green
    static let hackerGreen = Color(red: 0.0, green: 1.0, blue: 0.25)
    // Dark glass base color
    static let darkGlass = Color.black.opacity(0.4)
    // Subtle green border for glass effect
    static let glassBorder = hackerGreen.opacity(0.3)
}

extension ShapeStyle where Self == Color {
    static var hackerGreen: Color { Color.hackerGreen }
    static var darkGlass: Color { Color.darkGlass }
    static var glassBorder: Color { Color.glassBorder }
}

struct HackerTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.hackerGreen)
    }
}

struct LiquidGlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Material.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.darkGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.glassBorder, lineWidth: 1)
            )
            .shadow(color: Color.hackerGreen.opacity(0.1), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func hackerText() -> some View {
        self.modifier(HackerTextModifier())
    }
    
    func liquidGlassCard() -> some View {
        self.modifier(LiquidGlassCardModifier())
    }
    
    // Convenient global dark background
    func hackerBackground() -> some View {
        self.background(Color.black.edgesIgnoringSafeArea(.all))
    }
}
