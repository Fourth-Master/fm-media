import SwiftUI
import UIKit

/// FM影媒 视觉设计系统
enum FMTheme {
    static let accent = Color(hex: 0xFF5A1F)
    static let accentSoft = Color(hex: 0xFF8A4C)
    static let background = Color(hex: 0x0B0D10)
    static let surface = Color(hex: 0x15181E)
    static let surfaceHigh = Color(hex: 0x1E222A)
    static let separator = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let success = Color(hex: 0x3DD68C)
    static let warning = Color(hex: 0xFFB020)
    static let danger = Color(hex: 0xFF4D4F)

    static let cornerRadius: CGFloat = 14
    static let posterRadius: CGFloat = 10

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x101319), Color(hex: 0x07080A)],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

/// 通用卡片背景
struct FMCardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous)
                    .stroke(FMTheme.separator, lineWidth: 1)
            )
    }
}

extension View {
    func fmCard(padding: CGFloat = 14) -> some View {
        modifier(FMCardBackground(padding: padding))
    }

    func fmPrimaryButton() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(FMTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func fmSecondaryButton() -> some View {
        self
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(FMTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 标签胶囊
struct FMTag: View {
    let text: String
    var color: Color = FMTheme.accent

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }
}
