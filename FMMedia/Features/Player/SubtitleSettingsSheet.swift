import SwiftUI

struct SubtitleSettingsSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let delayMs: Int
    var onDelayChange: (Int) -> Void

    @State private var localDelay: Int

    init(delayMs: Int, onDelayChange: @escaping (Int) -> Void) {
        self.delayMs = delayMs
        self.onDelayChange = onDelayChange
        _localDelay = State(initialValue: delayMs)
    }

    private var style: Binding<SubtitleStyle> {
        $settings.data.subtitleStyle
    }

    private let textColors: [UInt32] = [0xFFFFFF, 0xFFE066, 0x7FE7FF, 0x8CFF9E, 0xFF9BD2, 0xFFB020]
    private let outlineColors: [UInt32] = [0x000000, 0x1A1A1A, 0x5A2E00, 0x00263A, 0x3A003A]

    var body: some View {
        FMNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview

                    group("时间轴") {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                delayButton("-0.5s", -500)
                                delayButton("-0.1s", -100)
                                Button {
                                    setDelay(0)
                                } label: {
                                    Text("归零")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(FMTheme.textPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(FMTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                delayButton("+0.1s", 100)
                                delayButton("+0.5s", 500)
                            }
                            HStack {
                                Text(String(format: "%+.2f 秒", Double(localDelay) / 1000))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(FMTheme.accent)
                                Spacer()
                                Text("正值 = 字幕更晚出现")
                                    .font(.system(size: 10))
                                    .foregroundStyle(FMTheme.textTertiary)
                            }
                            Slider(value: Binding(
                                get: { Double(localDelay) },
                                set: { setDelay(Int($0)) }
                            ), in: -10000...10000, step: 50)
                            .tint(FMTheme.accent)
                        }
                    }

                    group("字号与描边") {
                        VStack(spacing: 12) {
                            sliderRow(title: "字号", value: style.fontSize, range: 12...44, step: 1, format: "%.0f pt")
                            sliderRow(title: "描边", value: style.outlineWidth, range: 0...6, step: 0.5, format: "%.1f")
                            sliderRow(title: "底部距离", value: style.bottomInset, range: 0...240, step: 2, format: "%.0f")
                            sliderRow(title: "背景", value: style.backgroundOpacity, range: 0...1, step: 0.05, format: "%.2f")
                        }
                    }

                    group("颜色") {
                        VStack(alignment: .leading, spacing: 12) {
                            colorRow(title: "文字颜色", colors: textColors, selection: style.textColorHex)
                            colorRow(title: "描边颜色", colors: outlineColors, selection: style.outlineColorHex)
                        }
                    }

                    group("字形") {
                        HStack(spacing: 10) {
                            toggleChip("粗体", isOn: style.bold)
                            toggleChip("斜体", isOn: style.italic)
                            toggleChip("大写", isOn: style.uppercase)
                        }
                    }

                    Button {
                        settings.data.subtitleStyle = SubtitleStyle()
                        setDelay(0)
                    } label: {
                        Text("恢复默认样式").fmSecondaryButton()
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("字幕调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var preview: some View {
        VStack {
            Spacer()
            Text("字幕预览效果\nSubtitle preview")
                .font(previewFont)
                .foregroundStyle(Color(hex: settings.data.subtitleStyle.textColorHex))
                .shadow(color: Color(hex: settings.data.subtitleStyle.outlineColorHex),
                        radius: settings.data.subtitleStyle.outlineWidth)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(settings.data.subtitleStyle.backgroundOpacity),
                            in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(
            LinearGradient(colors: [Color(hex: 0x2A2F3A), Color(hex: 0x101319)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var previewFont: Font {
        var font = Font.system(size: settings.data.subtitleStyle.fontSize,
                               weight: settings.data.subtitleStyle.bold ? .bold : .semibold)
        if settings.data.subtitleStyle.italic {
            font = font.italic()
        }
        return font
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FMTheme.textTertiary)
            content()
        }
        .fmCard(padding: 14)
    }

    private func sliderRow(title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           format: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(FMTheme.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Slider(value: value, in: range, step: step)
                .tint(FMTheme.accent)
        }
    }

    private func colorRow(title: String, colors: [UInt32], selection: Binding<UInt32>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(FMTheme.textSecondary)
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        selection.wrappedValue = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(selection.wrappedValue == hex ? FMTheme.accent : FMTheme.separator,
                                                lineWidth: selection.wrappedValue == hex ? 2.5 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? .white : FMTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isOn.wrappedValue ? FMTheme.accent : FMTheme.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func delayButton(_ title: String, _ delta: Int) -> some View {
        Button {
            setDelay(localDelay + delta)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FMTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(FMTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func setDelay(_ value: Int) {
        localDelay = min(max(value, -10000), 10000)
        onDelayChange(localDelay)
    }
}
