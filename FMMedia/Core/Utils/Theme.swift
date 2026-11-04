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
    /// 支持 6 位（RRGGBB）与 8 位（RRGGBBAA）hex
    init(hex: UInt32, alpha: Double = 1.0) {
        if hex > 0xFFFFFF {
            let r = Double((hex >> 24) & 0xFF) / 255.0
            let g = Double((hex >> 16) & 0xFF) / 255.0
            let b = Double((hex >> 8) & 0xFF) / 255.0
            let a = Double(hex & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        } else {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
        }
    }
}

extension UIColor {
    /// 支持 6 位（RRGGBB）与 8 位（RRGGBBAA）hex
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        if hex > 0xFFFFFF {
            let r = CGFloat((hex >> 24) & 0xFF) / 255.0
            let g = CGFloat((hex >> 16) & 0xFF) / 255.0
            let b = CGFloat((hex >> 8) & 0xFF) / 255.0
            let a = CGFloat(hex & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: a)
        } else {
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: alpha)
        }
    }
}

// MARK: - 动态环境背景（深色=银河，浅色=云朵）

/// 深色模式：银河（固定星场闪烁 + 沿银河亮带密集星点 + 星云光晕）
struct GalaxyBackground: View {
    private struct Star {
        let x: CGFloat        // 0~1 相对坐标
        let y: CGFloat
        let radius: CGFloat
        let twinkleSpeed: Double
        let twinklePhase: Double
        let brightness: Double
    }

    /// 散布全屏的星点
    private static let fieldStars: [Star] = Self.makeStars(count: 200, saltBase: 0)
    /// 沿银河亮带高斯聚集的星点
    private static let bandStars: [Star] = Self.makeBandStars(count: 260, saltBase: 5000)
    /// 少量带光晕的亮星
    private static let brightStars: [Star] = Self.makeStars(count: 7, saltBase: 9000)

    /// 亮带路径与 drawBand 一致的三次贝塞尔
    private static func bandPoint(t: Double) -> CGPoint {
        let p0 = CGPoint(x: -0.1, y: 0.72)
        let p1 = CGPoint(x: 0.35, y: 0.45)
        let p2 = CGPoint(x: 0.65, y: 0.55)
        let p3 = CGPoint(x: 1.10, y: 0.28)
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    private static func makeStars(count: Int, saltBase: Double) -> [Star] {
        var result: [Star] = []
        for index in 0..<count {
            let s = Double(index) + saltBase
            let star = Star(x: CGFloat(rand(s, 12.9)),
                            y: CGFloat(rand(s, 78.2)),
                            radius: CGFloat(0.4 + rand(s, 9.1) * 0.8),
                            twinkleSpeed: 0.5 + rand(s, 3.7) * 1.2,
                            twinklePhase: s * 2.3,
                            brightness: 0.30 + rand(s, 5.3) * 0.45)
            result.append(star)
        }
        return result
    }

    private static func makeBandStars(count: Int, saltBase: Double) -> [Star] {
        var result: [Star] = []
        for index in 0..<count {
            let s = Double(index) + saltBase
            let t = rand(s, 21.7)
            // 两个均匀随机近似高斯的垂直散布
            let g = (rand(s, 47.1) + rand(s, 91.3) + rand(s, 33.3)) / 3.0 - 0.5
            let offset = g * 0.16
            let pos = bandPoint(t: t)
            let star = Star(x: min(max(pos.x + offset * 0.25, 0), 1),
                            y: min(max(pos.y + offset, 0), 1),
                            radius: CGFloat(0.3 + rand(s, 13.7) * 0.6),
                            twinkleSpeed: 0.4 + rand(s, 6.1) * 1.0,
                            twinklePhase: s * 1.7,
                            brightness: 0.25 + rand(s, 8.9) * 0.45)
            result.append(star)
        }
        return result
    }

    private static func rand(_ seed: Double, _ salt: Double) -> Double {
        let value = sin(seed * salt) * 43758.5453
        let fraction = value.truncatingRemainder(dividingBy: 1)
        return fraction < 0 ? fraction + 1 : fraction
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Self.drawBand(context: &context, size: size)
                Self.drawNebulae(context: &context, size: size, t: t)
                Self.drawStars(context: &context, size: size, t: t,
                               stars: Self.bandStars, scale: 0.55)
                Self.drawStars(context: &context, size: size, t: t,
                               stars: Self.fieldStars, scale: 1.0)
                Self.drawBrightStars(context: &context, size: size, t: t)
                Self.drawMeteors(context: &context, size: size, t: t)
            }
            .background(Color(hex: 0x07080A))
        }
        .ignoresSafeArea()
    }

    private static func drawNebulae(context: inout GraphicsContext, size: CGSize, t: Double) {
        // 星云沿亮带分布：取带上的三个点作为中心，缓慢呼吸
        let specs: [(Color, Double, CGFloat)] = [
            (Color(hex: 0x3A5BD9, alpha: 0.20), 0.22, 0.55),
            (Color(hex: 0x7A3AD9, alpha: 0.15), 0.52, 0.65),
            (Color(hex: 0x1F6FD9, alpha: 0.12), 0.80, 0.55)
        ]
        for spec in specs {
            let breathe = 1.0 + 0.08 * sin(t * 0.12 + Double(spec.2))
            let band = bandPoint(t: spec.1)
            let center = CGPoint(x: band.x * size.width,
                                 y: band.y * size.height)
            let radius = size.width * spec.2 * CGFloat(breathe)
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            let gradient = Gradient(colors: [spec.0, .clear])
            context.fill(Path(ellipseIn: rect),
                         with: .radialGradient(gradient, center: center,
                                               startRadius: 0, endRadius: radius))
        }
    }

    private static func drawStars(context: inout GraphicsContext, size: CGSize, t: Double,
                                  stars: [Star], scale: CGFloat) {
        for star in stars {
            let twinkle = 0.55 + 0.45 * sin(t * star.twinkleSpeed + star.twinklePhase)
            let opacity = star.brightness * twinkle
            guard opacity > 0.02 else { continue }
            let radius = star.radius * scale
            let rect = CGRect(x: star.x * size.width - radius,
                              y: star.y * size.height - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .color(.white.opacity(opacity)))
        }
    }

    private static func drawBrightStars(context: inout GraphicsContext, size: CGSize, t: Double) {
        for star in brightStars {
            let twinkle = 0.7 + 0.3 * sin(t * star.twinkleSpeed + star.twinklePhase)
            let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
            // 光晕极淡，只保留一点辉光，避免大圆点
            let haloRadius = star.radius * 2.2
            let halo = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                              width: haloRadius * 2, height: haloRadius * 2)
            context.fill(Path(ellipseIn: halo),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.10 * twinkle), .clear]),
                                               center: center, startRadius: 0, endRadius: haloRadius))
            let coreRadius = star.radius * 0.9
            let core = CGRect(x: center.x - coreRadius, y: center.y - coreRadius,
                              width: coreRadius * 2, height: coreRadius * 2)
            context.fill(Path(ellipseIn: core),
                         with: .color(.white.opacity(0.9 * twinkle)))
        }
    }

    /// 流星：按时间窗口确定性生成，约每 7 秒 / 13 秒各一颗（错开），随机起点与方向
    private static func drawMeteors(context: inout GraphicsContext, size: CGSize, t: Double) {
        let specs: [(interval: Double, phase: Double)] = [(7.0, 0.0), (13.0, 3.5)]
        for spec in specs {
            let elapsed = t - spec.phase
            guard elapsed > 0 else { continue }
            let window = floor(elapsed / spec.interval)
            let local = elapsed - window * spec.interval
            let duration = 1.1
            guard local < duration else { continue }

            let seed = window * 17.3 + spec.phase * 7.7
            let startX = 0.15 + rand(seed, 51.7) * 0.7          // 0.15~0.85
            let startY = rand(seed, 83.1) * 0.35                // 上半区
            let dirRight = rand(seed, 29.3) > 0.5
            let angle = (18.0 + rand(seed, 61.9) * 24.0) * .pi / 180.0   // 向下 18°~42°
            let dx = dirRight ? cos(angle) : -cos(angle)
            let dy = sin(angle)
            let travel = size.width * 0.32 * (local / duration)

            let headX = (startX * size.width) + CGFloat(dx * travel)
            let headY = (startY * size.height) + CGFloat(dy * travel)
            let tailLength = size.width * 0.09
            let tailX = headX - CGFloat(dx) * tailLength
            let tailY = headY - CGFloat(dy) * tailLength
            let fade = sin((local / duration) * .pi)             // 淡入淡出

            var line = Path()
            line.move(to: CGPoint(x: tailX, y: tailY))
            line.addLine(to: CGPoint(x: headX, y: headY))
            let gradient = Gradient(colors: [.clear, .white.opacity(0.85)])
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            context.drawLayer { layer in
                layer.opacity = fade
                layer.stroke(line, with: .linearGradient(gradient,
                                                         startPoint: CGPoint(x: tailX, y: tailY),
                                                         endPoint: CGPoint(x: headX, y: headY)),
                             style: style)
            }
            let headRadius = CGFloat(1.4)
            context.fill(Path(ellipseIn: CGRect(x: headX - headRadius, y: headY - headRadius,
                                                width: headRadius * 2, height: headRadius * 2)),
                         with: .color(.white.opacity(0.95 * fade)))
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
        let style = StrokeStyle(lineWidth: size.width * 0.24, lineCap: .round)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 60))
            layer.stroke(band, with: .linearGradient(gradient, startPoint: start, endPoint: end),
                         style: style)
        }
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

    /// 云朵鼓包（相对偏移 x/y 与半径比例）：
    /// 中间大、两端小、上下错落，形成不规则的云形
    private static let puffs: [(Double, Double, Double)] = [
        (-0.42, 0.05, 0.55),
        (-0.20, -0.18, 0.85),
        (-0.02, -0.32, 1.05),
        (0.18, -0.12, 0.90),
        (0.38, 0.02, 0.62),
        (0.52, 0.14, 0.45),
        (-0.30, 0.20, 0.60),
        (0.05, 0.26, 0.72),
        (0.34, 0.24, 0.52)
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
            // 环绕范围 -0.5 ~ 1.5（两屏宽）：云完全移出屏幕后才从另一侧重新进入，不会瞬移
            let cycle = (t * spec.speed / 90.0 + spec.baseX).truncatingRemainder(dividingBy: 2.0)
            let xNorm = cycle - 0.5
            let xDouble = xNorm * Double(size.width)
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
            // 两层绘制：底层柔光雾 + 上层较实云体，云更明显且边缘不规则
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: cloudHeight * 0.30 + 8))
                layer.fill(cluster, with: .color(.white.opacity(0.55)))
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: cloudHeight * 0.10 + 2))
                layer.fill(cluster, with: .color(.white.opacity(0.80)))
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

/// 统一玻璃面：半透明材质（让动态背景透出）+ 高光描边
private struct FMGlassFill<S: Shape>: View {
    var shape: S

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .opacity(0.68)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            )
    }
}

/// 通用卡片背景：液态玻璃
struct FMCardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                FMGlassFill(shape: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
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
        background(
            FMGlassFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
    }

    /// 液态玻璃胶囊（chips 等）
    func fmLiquidGlassCapsule() -> some View {
        background(FMGlassFill(shape: Capsule()))
    }

    /// 液态玻璃圆形（圆钮）
    func fmLiquidGlassCircle() -> some View {
        background(FMGlassFill(shape: Circle()))
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

/// 筛选 chip 背景：激活=强调色实底，非激活=液态玻璃+描边
struct FMChipBackground: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        if active {
            content.background(FMTheme.accent, in: Capsule())
        } else {
            content.fmLiquidGlassCapsule()
        }
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

// MARK: - List 行玻璃

/// List 行液态玻璃背景（配合 fmScrollContentBackgroundHidden 使用）
/// 玻璃面随行内容自然撑高，水平缩进 12pt + 圆角描边，隐藏系统分隔线
struct FMGlassListRow: ViewModifier {
    var cornerRadius: CGFloat = FMTheme.cornerRadius

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(
                FMGlassFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .padding(.vertical, 2)
            )
    }
}

extension View {
    /// 应用于 Section 或行视图，使整组行呈现液态玻璃
    func fmGlassListRow() -> some View {
        modifier(FMGlassListRow())
    }
}
