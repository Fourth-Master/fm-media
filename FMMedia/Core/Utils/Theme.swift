import SwiftUI
import UIKit

/// FM影媒 视觉设计系统（深/亮双模式自适应）
enum FMTheme {
    static let accent = Color(hex: 0xFF5A1F)
    static let accentSoft = Color(hex: 0xFF8A4C)
    static let success = Color(hex: 0x3DD68C)
    static let warning = Color(hex: 0xFFB020)
    static let danger = Color(hex: 0xFF4D4F)

    static let cornerRadius: CGFloat = 14
    static let posterRadius: CGFloat = 10

    /// 深亮自适应颜色：dark 值保持原有视觉，light 配套浅色
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let background = adaptive(light: 0xF3F5F9, dark: 0x0B0D10)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x15181E)
    static let surfaceHigh = adaptive(light: 0xE9EDF4, dark: 0x1E222A)
    static let separator = adaptive(light: 0x00000016, dark: 0xFFFFFF14)
    static let textPrimary = adaptive(light: 0x171A21, dark: 0xFFFFFF)
    static let textSecondary = adaptive(light: 0x3C4250E0, dark: 0xFFFFFF9E)
    static let textTertiary = adaptive(light: 0x6B728061, dark: 0xFFFFFF61)

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x101319) : UIColor(hex: 0xE8EDF6)
        }), Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x07080A) : UIColor(hex: 0xF6F8FC)
        })], startPoint: .top, endPoint: .bottom)
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

// MARK: - 动态环境背景（深色=银河，浅色=云朵）

/// 深色模式：缓缓流动的银河（星点 + 星云）
struct GalaxyBackground: View {
    private struct Nebula {
        let color: Color
        let baseX: CGFloat
        let baseY: CGFloat
        let radiusFactor: CGFloat
        let speed: Double
    }

    private static let nebulae: [Nebula] = [
        Nebula(color: Color(hex: 0x3A5BD9, alpha: 0.22), baseX: 0.28, baseY: 0.22, radiusFactor: 0.7, speed: 0.05),
        Nebula(color: Color(hex: 0x7A3AD9, alpha: 0.16), baseX: 0.75, baseY: 0.62, radiusFactor: 0.8, speed: 0.04),
        Nebula(color: Color(hex: 0x1F6FD9, alpha: 0.12), baseX: 0.50, baseY: 0.95, radiusFactor: 0.9, speed: 0.03)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Self.drawNebulae(context: &context, size: size, t: t)
                Self.drawStars(context: &context, size: size, t: t)
                Self.drawBand(context: &context, size: size)
            }
            .background(Color(hex: 0x07080A))
        }
        .ignoresSafeArea()
    }

    private static func drawNebulae(context: inout GraphicsContext, size: CGSize, t: Double) {
        for nebula in nebulae {
            let driftX = CGFloat(0.05 * sin(t * nebula.speed))
            let driftY = CGFloat(0.04 * cos(t * nebula.speed * 0.8))
            let center = CGPoint(x: size.width * (nebula.baseX + driftX),
                                 y: size.height * (nebula.baseY + driftY))
            let radius = size.width * nebula.radiusFactor
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            let gradient = Gradient(colors: [nebula.color, .clear])
            context.fill(Path(ellipseIn: rect),
                         with: .radialGradient(gradient, center: center,
                                               startRadius: 0, endRadius: radius))
        }
    }

    private static func drawStars(context: inout GraphicsContext, size: CGSize, t: Double) {
        for index in 0..<150 {
            let seed = Double(index)
            let baseX = CGFloat(pseudoRandom(seed: seed, salt: 12.9898))
            let baseY = CGFloat(pseudoRandom(seed: seed, salt: 78.233))
            let speed = 4.0 + (sin(seed * 3.7) * 0.5 + 0.5) * 10.0
            let x = baseX * size.width
            let rawY = baseY * size.height + CGFloat(t * speed)
            let y = rawY.truncatingRemainder(dividingBy: size.height)
            let twinkle = 0.35 + 0.65 * abs(sin(t * (0.6 + seed.truncatingRemainder(dividingBy: 3)) + seed))
            let radius = CGFloat(0.6 + (sin(seed * 9.1) * 0.5 + 0.5) * 1.1)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .color(.white.opacity(0.55 * twinkle)))
        }
    }

    private static func drawBand(context: inout GraphicsContext, size: CGSize) {
        var band = Path()
        band.move(to: CGPoint(x: -size.width * 0.1, y: size.height * 0.72))
        band.addCurve(to: CGPoint(x: size.width * 1.1, y: size.height * 0.28),
                      control1: CGPoint(x: size.width * 0.35, y: size.height * 0.45),
                      control2: CGPoint(x: size.width * 0.65, y: size.height * 0.55))
        let gradient = Gradient(colors: [.clear, .white.opacity(0.10), .clear])
        let start = CGPoint(x: 0, y: size.height * 0.7)
        let end = CGPoint(x: size.width, y: size.height * 0.3)
        let style = StrokeStyle(lineWidth: size.width * 0.22, lineCap: .round)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 60))
            layer.stroke(band, with: .linearGradient(gradient, startPoint: start, endPoint: end),
                         style: style)
        }
    }

    /// 确定性伪随机（0~1），跨帧稳定
    private static func pseudoRandom(seed: Double, salt: Double) -> Double {
        let value = sin(seed * salt) * 43758.5453
        let fraction = value.truncatingRemainder(dividingBy: 1)
        return fraction < 0 ? fraction + 1 : fraction
    }
}

/// 浅色模式：缓缓漂移的云朵
struct CloudsBackground: View {
    private struct CloudSpec {
        let baseX: Double
        let baseY: Double
        let widthFactor: Double
        let heightFactor: Double
        let speed: Double
    }

    private static let clouds: [CloudSpec] = [
        CloudSpec(baseX: 0.15, baseY: 0.22, widthFactor: 0.30, heightFactor: 0.05, speed: 9),
        CloudSpec(baseX: 0.55, baseY: 0.14, widthFactor: 0.36, heightFactor: 0.04, speed: 13),
        CloudSpec(baseX: 0.85, baseY: 0.38, widthFactor: 0.28, heightFactor: 0.06, speed: 7),
        CloudSpec(baseX: 0.30, baseY: 0.58, widthFactor: 0.42, heightFactor: 0.045, speed: 11),
        CloudSpec(baseX: 0.70, baseY: 0.78, widthFactor: 0.34, heightFactor: 0.055, speed: 15),
        CloudSpec(baseX: 0.10, baseY: 0.88, widthFactor: 0.30, heightFactor: 0.05, speed: 10)
    ]

    /// 云朵由多个椭圆鼓包组成（相对偏移与半径）
    private static let puffs: [(Double, Double, Double)] = [
        (-0.25, 0.10, 0.75),
        (0.00, -0.15, 1.00),
        (0.28, 0.05, 0.80),
        (0.05, 0.18, 0.90)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Self.drawSky(context: &context, size: size)
                Self.drawClouds(context: &context, size: size, t: t)
            }
            .background(Color(hex: 0xDCEBFA))
        }
        .ignoresSafeArea()
    }

    private static func drawSky(context: inout GraphicsContext, size: CGSize) {
        let sky = Gradient(colors: [Color(hex: 0xBBD7F5), Color(hex: 0xE9F3FC)])
        let rect = Path(CGRect(origin: .zero, size: size))
        context.fill(rect, with: .linearGradient(sky, startPoint: .zero,
                                                 endPoint: CGPoint(x: 0, y: size.height)))
    }

    private static func drawClouds(context: inout GraphicsContext, size: CGSize, t: Double) {
        for spec in clouds {
            let drift = (t * spec.speed / 60.0).truncatingRemainder(dividingBy: 1.6)
            let xDouble = ((spec.baseX + drift).truncatingRemainder(dividingBy: 1.4) - 0.2) * Double(size.width)
            let yDouble = spec.baseY * Double(size.height)
                + sin(t * 0.1 + spec.baseX * 7) * Double(size.height) * 0.012
            let x = CGFloat(xDouble)
            let y = CGFloat(yDouble)
            let cloudWidth = spec.widthFactor * Double(size.width)
            let cloudHeight = spec.heightFactor * Double(size.height)

            var cluster = Path()
            for puff in puffs {
                let px = x + CGFloat(puff.0 * cloudWidth)
                let py = y + CGFloat(puff.1 * cloudHeight)
                let pr = CGFloat(puff.2 * cloudHeight)
                cluster.addEllipse(in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 26))
                layer.fill(cluster, with: .color(.white.opacity(0.75)))
            }
        }
    }
}

extension CGRect {
    init(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        self.init(x: x, y: y, width: w, height: h)
    }
}

/// 页面环境背景：深色=银河 / 浅色=云朵，自动跟随系统外观
struct FMAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                GalaxyBackground()
            } else {
                CloudsBackground()
            }
        }
    }
}

extension View {
    /// 页面背景：动态银河 / 云朵
    func fmPageBackground() -> some View {
        background(FMAmbientBackground())
    }
}

// MARK: - 液态玻璃

/// 通用卡片背景：液态玻璃（材质 + 高光描边）
struct FMCardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}

extension View {
    func fmCard(padding: CGFloat = 14) -> some View {
        modifier(FMCardBackground(padding: padding))
    }

    /// 液态玻璃胶囊/面板（用于控件容器）
    func fmLiquidGlass(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
    }

    func fmPrimaryButton() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                LinearGradient(colors: [FMTheme.accent, FMTheme.accentSoft],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: FMTheme.accent.opacity(0.35), radius: 8, y: 3)
    }

    func fmSecondaryButton() -> some View {
        self
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(FMTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .fmLiquidGlass()
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
