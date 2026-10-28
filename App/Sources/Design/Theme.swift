import SwiftUI
import UIKit

/// MAIPA-G's own look: deep ink and soft paper, with one bright accent (mint unless changed) and
/// its partner colour for gradients.
struct Theme: Equatable {
    var accent: Color
    var partner: Color
    var effects: Effects
    /// iOS's Reduce Motion, which turns every moving effect off.
    var reduceMotion: Bool

    var sparkMoves: Bool { effects.sparkMoves && !reduceMotion }
    var backgroundGlow: Bool { effects.backgroundGlow && !reduceMotion }
    var thinkingShimmer: Bool { effects.thinkingShimmer && !reduceMotion }
    var messagesSlideIn: Bool { effects.messagesSlideIn && !reduceMotion }

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, partner], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func make(_ settings: AppSettings, reduceMotion: Bool) -> Theme {
        let (accent, partner) = Palette.colors(for: settings.accent)
        return Theme(accent: accent, partner: partner, effects: settings.effects, reduceMotion: reduceMotion)
    }

    static let standard = Theme(accent: Palette.mint, partner: Palette.sky, effects: Effects(), reduceMotion: false)

    // Surfaces, the same whatever the accent.
    static let background = Color(light: 0xF6F7F4, dark: 0x0B0F14)
    static let surface = Color(light: 0xFFFFFF, dark: 0x121821)
    static let raised = Color(light: 0xFFFFFF, dark: 0x19212C)
    static let sunken = Color(light: 0xEEF0EC, dark: 0x0F141B)
    static let stroke = Color(light: 0x0E141B, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    static let secondaryText = Color(light: 0x5B6672, dark: 0x9AA7B6)
    static let codeBackground = Color(light: 0xF0F2EE, dark: 0x0E141B)
    static let userBubble = Color(light: 0xE4F6F0, dark: 0x16302B)
    static let danger = Color(light: 0xD23B3B, dark: 0xFF6B6B)
}

enum Palette {
    static let mint = Color(light: 0x0FA383, dark: 0x2EE6B6)
    static let sky = Color(light: 0x1F7FD6, dark: 0x33A6FF)
    static let violet = Color(light: 0x6F4FE0, dark: 0x9B7BFF)
    static let rose = Color(light: 0xD63A7C, dark: 0xFF5FA2)
    static let coral = Color(light: 0xE0533F, dark: 0xFF7A6B)
    static let gold = Color(light: 0xB57A00, dark: 0xFFB547)

    static func colors(for choice: AccentChoice) -> (Color, Color) {
        switch choice {
        case .mint: return (mint, sky)
        case .sky: return (sky, violet)
        case .violet: return (violet, rose)
        case .rose: return (rose, violet)
        case .coral: return (coral, gold)
        case .gold: return (gold, coral)
        }
    }
}

extension Color {
    /// A colour that follows Dark and Light mode.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.standard
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Font {
    /// The rounded face MAIPA-G uses for headings.
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}
