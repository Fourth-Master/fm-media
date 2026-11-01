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
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                // 星云：两团缓慢漂移的径向渐变
                let nebulae: [(Color, CGPoint, CGFloat, Double, Double)] = [
                    (Color(hex: 0x3A5BD9, alpha: 0.22),
                     CGPoint(x: size.width * (0.28 + 0.05 * sin(t * 0.05)), y: size.height * (0.22 + 0.04 * cos(t * 0.04))), size.width * 0.7, 0, 0),
                    (Color(hex: 0x7A3AD9, alpha: 0.16),
                     CGPoint(x: size.width * (0.75 + 0.04 * cos(t * 0.035)), y: size.height * (0.62 + 0.05 * sin(t * 0.045))), size.width * 0.8, 0, 0),
                    (Color(hex: 0x1F6FD9, alpha: 0.12),
                     CGPoint(x: size.width * 0.5, y: size.height * (0.95 + 0.03 * sin(t * 0.03))), size.width * 0.9, 0, 0)
                ]
                for (color, center, radius, _, _) in nebulae {
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .radialGradient(Gradient(colors: [color, .clear]),
                                                       center: center, startRadius: 0, endRadius: radius))
                }

                // 星点：确定性伪随机，缓慢下移闪烁
                let count = 150
                for index in 0..<count {
                    let seed = Double(index)
                    let baseX = (sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let baseY = (sin(seed * 78.233) * 12345.6789).truncatingRemainder(dividingBy: 1)
                    let speed = 4 + (sin(seed * 3.7) * 0.5 + 0.5) * 10
                    let x = (baseX < 0 ? baseX + 1 : baseX) * size.width
                    let y = ((baseY < 0 ? baseY + 1 : baseY) * size.height + t * speed)
                        .truncatingRemainder(dividingBy: size.height)
                    let twinkle = 0.35 + 0.65 * abs(sin(t * (0.6 + seed.truncatingRemainder(dividingBy: 3)) + seed))
                    let radius = 0.6 + (sin(seed * 9.1) * 0.5 + 0.5) * 1.1
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(.white.opacity(0.55 * twinkle)))
                }

                // 银河亮带：斜向柔光
                var band = Path()
                band.move(to: CGPoint(x: -size.width * 0.1, y: size.height * 0.72))
                band.addCurve(to: CGPoint(x: size.width * 1.1, y: size.height * 0.28),
                              control1: CGPoint(x: size.width * 0.35, y: size.height * 0.45),
                              control2: CGPoint(x: size.width * 0.65, y: size.height * 0.55))
                context.drawLayer { layer in
                    layer.addFilter(.blur(width: 60))
                    layer.stroke(band,
                                 with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.10), .clear]),
                                                       startPoint: CGPoint(x: 0, y: size.height * 0.7),
                                                       endPoint: CGPoint(x: size.width, y: size.height * 0.3)),
                                 style: StrokeStyle(lineWidth: size.width * 0.22, lineCap: .round))
                }
            }
            .background(Color(hex: 0x07080A))
        }
        .ignoresSafeArea()
    }
}

/// 浅色模式：缓缓漂移的云朵
struct CloudsBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                let sky = Gradient(colors: [Color(hex: 0xBBD7F5), Color(hex: 0xE9F3FC)])
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .linearGradient(sky, startPoint: .zero,
                                                   endPoint: CGPoint(x: 0, y: size.height)))

                // 云朵：不同速度横向漂移的柔光椭圆簇
                let cloudSpecs: [(Double, Double, Double, Double, Double)] = [
                    (0.15, 0.22, 0.30, 0.05, 9),
                    (0.55, 0.14, 0.36, 0.04, 13),
                    (0.85, 0.38, 0.28, 0.06, 7),
                    (0.30, 0.58, 0.42, 0.045, 11),
                    (0.70, 0.78, 0.34, 0.055, 15),
                    (0.10, 0.88, 0.30, 0.05, 10)
                ]
                for (bx, by, w, h, speed) in cloudSpecs {
                    let drift = (t * Double(speed) / 60.0).truncatingRemainder(dividingBy: 1.6)
                    let x = ((bx + drift).truncatingRemainder(dividingBy: 1.4) - 0.2) * size.width
                    let y = by * size.height + sin(t * 0.1 + bx * 7) * size.height * 0.012
                    let cw = w * size.width
                    let ch = h * size.height
                    var cluster = Path()
                    for puff in [(-0.25, 0.1, 0.75), (0.0, -0.15, 1.0), (0.28, 0.05, 0.8), (0.05, 0.18, 0.9)] {
                        let px = x + puff.0 * cw
                        let py = y + puff.1 * ch
                        let pr = puff.2 * ch
                        cluster.addEllipse(in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
                    }
                    context.drawLayer { layer in
                        layer.addFilter(.blur(width: 26))
                        layer.fill(cluster, with: .color(.white.opacity(0.75)))
                    }
                }
            }
            .background(Color(hex: 0xDCEBFA))
        }
        .ignoresSafeArea()
    }
}

private extension Path {
    mutating func addEllipse(_ rect: CGRect) {
        addEllipse(in: rect)
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
