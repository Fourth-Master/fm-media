import SwiftUI

// MARK: - 通用组件

/// 支持左滑露出操作按钮的行容器（用于非 List 场景）
struct FMSwipeRow<Actions: View, Content: View>: View {
    var actionsWidth: CGFloat = 72
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    @State private var offsetX: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    private var currentOffset: CGFloat {
        let base = -actionsWidth * (offsetX < -actionsWidth / 2 ? 1 : 0)
        return min(0, max(-actionsWidth * 1.4, base + dragOffset))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack {
                Spacer(minLength: 0)
                actions()
                    .frame(width: actionsWidth)
                    .padding(.trailing, 8)
            }
            content()
                .background(FMTheme.surface)
                .offset(x: currentOffset)
                .gesture(swipeGesture)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: currentOffset)
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragOffset) { value, state, _ in
                // 仅响应水平主导的拖动，避免干扰纵向滚动
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start = offsetX < -actionsWidth / 2 ? -actionsWidth : 0
                let target = start + value.translation.width
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    offsetX = target < -actionsWidth / 2 ? -actionsWidth : 0
                }
            }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(FMTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FMTheme.textTertiary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FMTheme.accent)
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = FMTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FMTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FMSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索番号、标题、演员"
    /// 输入法「搜索」键（回车）触发
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FMTheme.textTertiary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(FMTheme.textPrimary)
                .font(.system(size: 14))
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FMTheme.textTertiary)
                }
            }
            // 最右侧：关闭输入法
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15))
                    .foregroundStyle(FMTheme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FMTheme.separator, lineWidth: 1)
        )
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(FMTheme.textTertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FMTheme.textSecondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(FMTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FMTheme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct ProgressBarView: View {
    var progress: Double
    var height: CGFloat = 3
    var tint: Color = FMTheme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct SourceIcon: View {
    let kind: SourceKind
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(FMTheme.accent)
            .frame(width: size, height: size)
            .background(FMTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct LoadingBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(FMTheme.textSecondary)
            Spacer()
        }
        .padding(12)
        .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 媒体卡片

extension MediaItem {
    /// 按设置过滤后的角标
    func displayBadges(showCracked: Bool, showSubtitle: Bool) -> [String] {
        var result: [String] = []
        if isCracked && showCracked { result.append("破解") }
        if hasSubtitleFiles && showSubtitle { result.append("字幕") }
        if !isRecognized { result.append("未识别") }
        return result
    }
}

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 118

    @EnvironmentObject private var settings: AppSettings

    private var resolved: DisplayTitle {
        TitleResolver.resolve(item: item,
                              mode: settings.data.titleMode,
                              titleField: settings.data.titleField,
                              subtitleFields: settings.data.subtitleFields)
    }

    private var badges: [String] {
        item.displayBadges(showCracked: settings.data.showCrackedBadge,
                           showSubtitle: settings.data.showSubtitleBadge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                FMImageView(ref: item.poster, cornerRadius: FMTheme.posterRadius)
                    .frame(width: width, height: width * 1.42)
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: FMTheme.posterRadius, style: .continuous))
                    .frame(width: width, height: width * 1.42)
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges.prefix(2), id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(FMTheme.accent.opacity(0.9), in: Capsule())
                        }
                    }
                    .padding(6)
                }
                if item.playProgress > 5 {
                    ProgressBarView(progress: item.playProgress / max(item.durationSeconds ?? 0, 1))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
            }
            .frame(width: width, height: width * 1.42)

            Text(resolved.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FMTheme.textPrimary)
                .lineLimit(settings.data.showFullTitle ? nil : 1)
                .fixedSize(horizontal: false, vertical: settings.data.showFullTitle)
                .multilineTextAlignment(.leading)
            if !resolved.subtitle.isEmpty {
                Text(resolved.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
                    .lineLimit(settings.data.showFullTitle ? nil : 1)
                    .fixedSize(horizontal: false, vertical: settings.data.showFullTitle)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct WideCard: View {
    let item: MediaItem
    var width: CGFloat = 220

    @EnvironmentObject private var settings: AppSettings

    private var resolved: DisplayTitle {
        TitleResolver.resolve(item: item,
                              mode: settings.data.titleMode,
                              titleField: settings.data.titleField,
                              subtitleFields: settings.data.subtitleFields)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                FMImageView(ref: item.fanart ?? item.poster, cornerRadius: 10)
                    .frame(width: width, height: width * 0.58)
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(width: width, height: width * 0.58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if item.playProgress > 5 {
                        ProgressBarView(progress: item.playProgress / max(item.durationSeconds ?? 0, 1))
                            .frame(width: width - 20)
                    }
                }
                .padding(10)
            }
            .frame(width: width, height: width * 0.58)
        }
        .frame(width: width, alignment: .leading)
    }
}
