import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import MediaPlayer

/// 通用播放画面（MPV / VLC 内核共用）
struct PlayerSurface: UIViewRepresentable {
    let engine: PlaybackEngine

    func makeUIView(context: Context) -> UIView {
        engine.makeView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 播放页

struct PlayerScreen: View {
    let request: PlaybackRequest

    @StateObject private var vm: PlayerViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var subtitles: SubtitleLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showSubtitlePanel = false
    @State private var showSubtitleSearch = false
    @State private var showImportSubtitle = false
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var seekHint: String? = nil
    @State private var viewSize: CGSize = .zero
    @State private var dragMode: DragMode = .none
    @State private var dragStartTime: Double = 0
    @State private var dragDelta: Double = 0
    @State private var dragStartBrightness: Double = 0
    @State private var dragStartVolume: Double = 0
    @State private var hud: PlayerHUD?
    @State private var isBoosting = false
    @State private var boostBaseRate: Double = 1.0

    init(request: PlaybackRequest) {
        self.request = request
        _vm = StateObject(wrappedValue: PlayerViewModel(request: request))
    }

    private var itemIDForSubtitles: String {
        request.media?.id ?? "player-\(request.stream.url.absoluteString)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(engine: vm.engine)
                .id(vm.engineID)
                .ignoresSafeArea()

            gestureLayer

            SubtitleOverlayView(cue: vm.activeCue, style: settings.data.subtitleStyle)

            if vm.isLoading {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                        .scaleEffect(1.2)
                    Text(vm.isBuffering ? "缓冲中…" : "正在打开…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    if vm.networkSpeed > 1024 {
                        Text(Self.speedText(vm.networkSpeed))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(18)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if vm.showControls {
                controls
                    .transition(.opacity)
            }

            if let hud {
                VStack {
                    hudView(hud)
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity)
            }

            if let hint = seekHint {
                Text(hint)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.65), in: Capsule())
            }

            if let notice = vm.notice {
                VStack {
                    Text(notice)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.opacity)
            }

            if let error = vm.errorMessage {
                errorOverlay(error)
            }
        }
        .fmPlayerChrome()
        .task {
            await MainActor.run {
                vm.setRate(settings.data.playbackRate)
            }
            await vm.start(preferred: settings.data.enginePreference, decode: settings.data.decodePreference)
            await MainActor.run {
                scheduleAutoHide()
            }
        }
        .onDisappear {
            hideTask?.cancel()
            vm.cleanup()
            // 横屏播放退出后恢复竖屏，避免下层页面残留横屏
            OrientationManager.set(.portrait)
        }
        .sheet(isPresented: $showSubtitlePanel) {
            SubtitleSettingsSheet(delayMs: vm.subtitleDelay,
                                  onDelayChange: { vm.setSubtitleDelay($0) })
        }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchSheet(code: searchCode,
                                itemID: itemIDForSubtitles,
                                titleHint: request.displayTitle,
                                media: request.media,
                                onApply: { url in vm.applySubtitleFile(url) })
        }
        .fileImporter(isPresented: $showImportSubtitle,
                      allowedContentTypes: subtitleTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importSubtitle(url: url)
            }
        }
    }

    private var searchCode: String {
        if let media = request.media { return media.code }
        let name = request.displayTitle
        if let parsed = MediaCodeParser.find(in: name) { return parsed.number }
        return name
    }

    private var subtitleTypes: [UTType] {
        let types = ["srt", "ass", "ssa", "vtt", "sub", "smi"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.plainText] : types
    }

    // MARK: - 手势层

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flashSeek(-10) }
                .onTapGesture { toggleControls() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flashSeek(10) }
                .onTapGesture { toggleControls() }
        }
        .simultaneousGesture(seekAndLevelsGesture)
        .onLongPressGesture(minimumDuration: 0.5,
                            maximumDistance: 14,
                            pressing: { pressing in
                                if !pressing { endBoost() }
                            },
                            perform: { startBoost() })
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewSize = proxy.size }
                    .onChange(of: proxy.size) { newSize in viewSize = newSize }
            }
        )
    }

    private var seekAndLevelsGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                if dragMode == .none {
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    if horizontal {
                        dragMode = .seek
                        dragStartTime = vm.currentTime
                    } else if value.startLocation.x < viewSize.width / 2 {
                        dragMode = .brightness
                        dragStartBrightness = Double(UIScreen.main.brightness)
                    } else {
                        dragMode = .volume
                        dragStartVolume = Double(SystemVolume.current())
                    }
                    if dragMode != .none { showControlsTemporarily() }
                }

                let height = max(viewSize.height, 1)
                switch dragMode {
                case .seek:
                    let width = max(viewSize.width, 1)
                    let delta = Double(value.translation.width / width) * 180
                    dragDelta = delta
                    let upper = max(vm.duration, 0)
                    let target = min(max(dragStartTime + delta, 0), upper > 0 ? upper : dragStartTime + delta)
                    hud = .seek(target: target, delta: delta)

                case .brightness:
                    let next = min(max(dragStartBrightness - Double(value.translation.height / height), 0), 1)
                    UIScreen.main.brightness = CGFloat(next)
                    hud = .brightness(next)

                case .volume:
                    let next = min(max(dragStartVolume - Double(value.translation.height / height), 0), 1)
                    SystemVolume.set(Float(next))
                    hud = .volume(next)

                case .none:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .seek {
                    vm.seek(to: dragStartTime + dragDelta)
                }
                dragMode = .none
                hud = nil
            }
    }

    private func startBoost() {
        guard !isBoosting, !vm.isLoading else { return }
        isBoosting = true
        boostBaseRate = vm.playbackRate
        let rate = settings.data.longPressRate
        vm.setRate(rate)
        hud = .rate(rate)
    }

    private func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        vm.setRate(boostBaseRate)
        hud = nil
    }

    private func flashSeek(_ seconds: Double) {
        vm.skip(seconds)
        let text = seconds > 0 ? "快进 10 秒" : "后退 10 秒"
        seekHint = text
        showControlsTemporarily()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if seekHint == text { seekHint = nil }
        }
    }

    // MARK: - 控制层

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(vm.engineName)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.16), in: Capsule())
                    if let name = vm.subtitleName {
                        Text(name)
                            .lineLimit(1)
                    } else {
                        Text("无字幕")
                    }
                    if vm.subtitleDelay != 0 {
                        Text(String(format: "%+.1fs", Double(vm.subtitleDelay) / 1000))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            Button {
                showSubtitleSearch = true
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            Menu {
                subtitleMenu
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            Menu {
                Button {
                    showSubtitlePanel = true
                } label: {
                    Label("字幕样式与同步", systemImage: "slider.horizontal.3")
                }
                Button {
                    showImportSubtitle = true
                } label: {
                    Label("导入本地字幕", systemImage: "square.and.arrow.down")
                }
                Divider()
                Menu {
                    ForEach(PlayerAspect.allCases) { aspect in
                        Button {
                            vm.setAspect(aspect)
                        } label: {
                            if vm.aspect == aspect {
                                Label(aspect.title, systemImage: "checkmark")
                            } else {
                                Text(aspect.title)
                            }
                        }
                    }
                } label: {
                    Label("画面比例（" + vm.aspect.title + "）", systemImage: "aspectratio")
                }
                Menu {
                    Button {
                        vm.selectAudioTrack(nil)
                    } label: {
                        if vm.selectedAudioID == nil {
                            Label("自动", systemImage: "checkmark")
                        } else {
                            Text("自动")
                        }
                    }
                    if vm.audioTracks.isEmpty {
                        Text("暂无音轨信息")
                    } else {
                        ForEach(vm.audioTracks) { track in
                            Button {
                                vm.selectAudioTrack(track.id)
                            } label: {
                                if vm.selectedAudioID == track.id {
                                    Label(track.name, systemImage: "checkmark")
                                } else {
                                    Text(track.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label("音轨 / 声道", systemImage: "speaker.wave.2")
                }
                Menu {
                    Button {
                        vm.selectVideoTrack(nil)
                    } label: {
                        if vm.selectedVideoID == nil {
                            Label("自动", systemImage: "checkmark")
                        } else {
                            Text("自动")
                        }
                    }
                    if vm.videoTracks.isEmpty {
                        Text("暂无视频轨道信息")
                    } else {
                        ForEach(vm.videoTracks) { track in
                            Button {
                                vm.selectVideoTrack(track.id)
                            } label: {
                                if vm.selectedVideoID == track.id {
                                    Label(track.name, systemImage: "checkmark")
                                } else {
                                    Text(track.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label("视频轨道", systemImage: "film")
                }
                Menu {
                    ForEach(PlaybackDecodeMode.allCases) { mode in
                        Button {
                            vm.switchDecodeMode(mode)
                            settings.data.decodePreference = mode
                        } label: {
                            if vm.decodeMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Label("解码方式（" + vm.decodeMode.title + "）", systemImage: "cpu")
                }
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            vm.setRate(rate)
                            settings.data.playbackRate = rate
                        } label: {
                            if abs(vm.playbackRate - rate) < 0.01 {
                                Label("\(rate.formatted())×", systemImage: "checkmark")
                            } else {
                                Text("\(rate.formatted())×")
                            }
                        }
                    }
                } label: {
                    Label("播放速度", systemImage: "speedometer")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        Button {
            vm.selectSubtitle(nil)
        } label: {
            if vm.selectedSubtitleID == nil {
                Label("关闭字幕", systemImage: "checkmark")
            } else {
                Text("关闭字幕")
            }
        }
        if vm.subtitleOptions.isEmpty {
            Text("暂无可用字幕")
        } else {
            ForEach(vm.subtitleOptions) { option in
                Button {
                    vm.selectSubtitle(option.id)
                } label: {
                    if vm.selectedSubtitleID == option.id {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        }
        Divider()
        Button {
            showSubtitleSearch = true
        } label: {
            Label("在线搜索字幕", systemImage: "magnifyingglass")
        }
    }

    private var centerControls: some View {
        HStack(spacing: 46) {
            Button {
                vm.skip(-10)
                showControlsTemporarily()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)
            }

            Button {
                vm.togglePlay()
                showControlsTemporarily()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.white.opacity(0.16), in: Circle())
            }

            Button {
                vm.skip(10)
                showControlsTemporarily()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            PlayerSeekBar(vm: vm)
                .frame(height: 26)

            HStack(spacing: 8) {
                Text((vm.isSeeking ? vm.seekTarget : vm.currentTime).timecode)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text("/")
                    .foregroundStyle(.white.opacity(0.4))
                Text(vm.duration.timecode)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if vm.isBuffering {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                // 下载速度（倍速前）
                if vm.networkSpeed > 1024 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                        Text(Self.speedText(vm.networkSpeed))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
                Text("\(vm.playbackRate.formatted())×")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                // 横竖屏切换（右下角）
                Button {
                    OrientationManager.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(FMTheme.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            if vm.decodeMode != .software {
                Text("当前内核（" + vm.engineName + "）无法播放该视频，可尝试切换为软件解码后重试。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 10) {
                if vm.decodeMode != .software {
                    Button("软件解码重试") {
                        vm.retryWithSoftwareDecode()
                    }
                    .fmSecondaryButton()
                } else {
                    Button("重新加载") {
                        vm.reload()
                    }
                    .fmSecondaryButton()
                }
                Button("关闭") { dismiss() }
                    .fmSecondaryButton()
            }
            .frame(width: 280)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func hudView(_ hud: PlayerHUD) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hud.symbolName)
                .font(.system(size: 14, weight: .semibold))
            Text(hud.text)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.7), in: Capsule())
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1048576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    // MARK: - 控制条显示

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            vm.showControls.toggle()
        }
        if vm.showControls {
            scheduleAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func showControlsTemporarily() {
        if !vm.showControls {
            withAnimation(.easeInOut(duration: 0.2)) {
                vm.showControls = true
            }
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard vm.isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, vm.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                vm.showControls = false
            }
        }
    }
}

// MARK: - 进度条

struct PlayerSeekBar: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var dragging = false
    @State private var dragProgress: Double = 0

    var body: some View {
        GeometryReader { geo in
            let progress = dragging
                ? dragProgress
                : (vm.duration > 0 ? vm.currentTime / vm.duration : 0)
            let clamped = min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                Capsule()
                    .fill(FMTheme.accent)
                    .frame(width: geo.size.width * clamped, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 15 : 11, height: dragging ? 15 : 11)
                    .offset(x: max(0, geo.size.width * clamped - (dragging ? 7.5 : 5.5)))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard vm.duration > 0 else { return }
                        dragging = true
                        let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                        dragProgress = ratio
                        vm.isSeeking = true
                        vm.seekTarget = ratio * vm.duration
                    }
                    .onEnded { value in
                        guard vm.duration > 0 else { dragging = false; return }
                        let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                        vm.seek(to: ratio * vm.duration)
                        dragging = false
                    }
            )
        }
    }
}

// MARK: - 字幕覆盖层

struct SubtitleOverlayView: View {
    let cue: SubtitleCue?
    let style: SubtitleStyle

    var body: some View {
        VStack {
            Spacer()
            if let cue {
                SubtitleText(cue: cue, style: style)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, style.bottomInset)
        .animation(.easeOut(duration: 0.12), value: cue?.id)
        .allowsHitTesting(false)
    }
}

struct SubtitleText: View {
    let cue: SubtitleCue
    let style: SubtitleStyle

    private var text: String {
        style.uppercase ? cue.text.uppercased() : cue.text
    }

    private var font: Font {
        .system(size: style.fontSize, weight: style.bold || cue.bold ? .bold : .semibold)
    }

    private var color: Color { Color(hex: style.textColorHex) }
    private var outline: Color { Color(hex: style.outlineColorHex) }

    private var offsets: [CGSize] {
        let w = max(0.5, style.outlineWidth)
        return [
            CGSize(width: -w, height: 0), CGSize(width: w, height: 0),
            CGSize(width: 0, height: -w), CGSize(width: 0, height: w),
            CGSize(width: -w, height: -w), CGSize(width: w, height: w),
            CGSize(width: -w, height: w), CGSize(width: w, height: -w)
        ]
    }

    var body: some View {
        ZStack {
            if style.outlineWidth > 0.1 {
                ForEach(Array(offsets.indices), id: \.self) { index in
                    styledText.foregroundStyle(outline).offset(offsets[index])
                }
            }
            styledText.foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Group {
                if style.backgroundOpacity > 0.01 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(style.backgroundOpacity))
                } else {
                    Color.clear
                }
            }
        )
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }

    private var styledText: Text {
        var text = Text(self.text)
            .font(font)
        if style.italic || cue.italic {
            text = text.italic()
        }
        return text
    }
}


// MARK: - 手势辅助类型

private enum DragMode {
    case none
    case seek
    case brightness
    case volume
}

private enum PlayerHUD: Equatable {
    case seek(target: Double, delta: Double)
    case brightness(Double)
    case volume(Double)
    case rate(Double)

    var symbolName: String {
        switch self {
        case .seek(_, let delta):
            return delta >= 0 ? "goforward" : "gobackward"
        case .brightness: return "sun.max.fill"
        case .volume: return "speaker.wave.2.fill"
        case .rate: return "forward.fill"
        }
    }

    var text: String {
        switch self {
        case .seek(let target, let delta):
            return String(format: "%@%.0fs  %@", delta >= 0 ? "+" : "", delta, target.timecode)
        case .brightness(let value):
            return "亮度 \(Int(value * 100))%"
        case .volume(let value):
            return "音量 \(Int(value * 100))%"
        case .rate(let value):
            return String(format: "%.1f× 倍速播放中", value)
        }
    }
}

enum SystemVolume {
    private static let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    private static var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    static func current() -> Float {
        if let value = slider?.value { return value }
        return AVAudioSession.sharedInstance().outputVolume
    }

    static func set(_ value: Float) {
        DispatchQueue.main.async {
            slider?.value = min(max(value, 0), 1)
        }
    }
}
