import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 播放会话：负责状态聚合、字幕、进度与内核切换
/// 实际解码播放交给 `PlaybackEngine`（系统 AVPlayer 或 VLC）
@MainActor
final class PlayerViewModel: ObservableObject {
    struct SubtitleOption: Identifiable, Hashable {
        var id: String
        var name: String
        var url: URL?
        var isEmbedded: Bool = false
    }

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var didReachEnd = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = true
    @Published private(set) var engineName: String = "系统"
    @Published private(set) var engineID = UUID()
    @Published private(set) var decodeMode: PlaybackDecodeMode = .auto
    @Published private(set) var networkSpeed: Double = 0
    @Published private(set) var audioTracks: [PlaybackAudioTrack] = []
    @Published private(set) var videoTracks: [PlaybackVideoTrack] = []
    @Published var selectedAudioID: String?
    @Published var selectedVideoID: String?
    @Published private(set) var aspect: PlayerAspect = .auto
    @Published var notice: String?
    /// 打开失败自动重试计数（每次播放最多静默重试一次）
    private var openRetryCount = 0

    @Published var cues: [SubtitleCue] = []
    @Published var activeCue: SubtitleCue?
    @Published var subtitleName: String?
    @Published var subtitleOptions: [SubtitleOption] = []
    @Published var selectedSubtitleID: String?
    @Published var showControls = true
    @Published var isSeeking = false
    @Published var seekTarget: Double = 0
    @Published var playbackRate: Double = 1.0

    let request: PlaybackRequest
    private(set) var engine: PlaybackEngine

    private var sidecarOptions: [SubtitleOption] = []
    private var delayMs: Int = 0
    private var lastNowPlayingUpdate = Date.distantPast
    private var watchdog: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var currentKind: PlaybackEngineKind = .auto


    init(request: PlaybackRequest) {
        self.request = request
        // 占位引擎：真正播放前会被 buildEngine 替换，用 VLC 避免提前创建 GL 视图
        self.engine = PlaybackEngineFactory.make(kind: .auto, pathExtension: "")
        configureAudioSession()
        setupRemoteCommands()
        wire(engine)
        addSubtitles(request.subtitles)
    }

    // MARK: - 生命周期

    func start(preferred: PlaybackEngineKind = .auto, decode: PlaybackDecodeMode = .auto) async {
        decodeMode = decode
        isLoading = true
        didReachEnd = false
        errorMessage = nil
        openRetryCount = 0
        currentTime = 0
        duration = 0
        networkSpeed = 0
        audioTracks = []
        selectedAudioID = nil
        videoTracks = []
        selectedVideoID = nil
        AppDebugLog.write("[Player] start kind=\(preferred.rawValue) decode=\(decode.rawValue) ext=\(streamExtension)")

        var kind = preferred

        buildEngine(kind, at: max(0, request.startAt))
        await fetchRemoteSubtitles()
        autoLoadSidecarSubtitle()
        startWatchdog()
    }

    func cleanup() {
        watchdog?.cancel()
        networkSpeed = 0
        noticeTask?.cancel()
        saveProgressIfNeeded()
        engine.teardown()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var streamExtension: String {
        if let media = request.media, let video = media.video {
            let ext = (video.name as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        return request.stream.url.pathExtension.lowercased()
    }

    private func buildEngine(_ kind: PlaybackEngineKind, at position: Double) {
        engine.teardown()
        currentKind = kind
        let newEngine = PlaybackEngineFactory.make(kind: kind, pathExtension: streamExtension, decode: decodeMode)
        engine = newEngine
        engineName = newEngine.name
        engineID = UUID()
        AppDebugLog.write("[Player] engine=\(newEngine.name) kind=\(kind.rawValue) startAt=\(position)")
        wire(newEngine)
        newEngine.load(request.stream, startAt: position, rate: playbackRate)
        newEngine.setAspect(aspect)
        refreshSubtitleOptions()
        refreshAudioTracks()
    }

    private func wire(_ engine: PlaybackEngine) {
        engine.onTime = { [weak self] time in
            guard let self else { return }
            self.currentTime = time
            self.updateActiveCue()
            self.updateNowPlaying(force: false)
        }
        engine.onDuration = { [weak self] seconds in
            guard let self, seconds.isFinite, seconds > 0 else { return }
            self.duration = seconds
        }
        engine.onPlaybackState = { [weak self] playing, buffering in
            guard let self else { return }
            self.isPlaying = playing
            self.isBuffering = buffering
            if playing || !buffering {
                self.isLoading = false
            }
        }
        engine.onTracks = { [weak self] in
            self?.refreshSubtitleOptions()
            self?.refreshAudioTracks()
        }
        engine.onEnd = { [weak self] in
            guard let self else { return }
            self.didReachEnd = true
            self.saveProgressIfNeeded()
        }
        engine.onError = { [weak self] message in
            self?.handleEngineError(message)
        }
        engine.onSpeed = { [weak self] value in
            guard let self else { return }
            self.networkSpeed = max(0, value)
        }
        engine.onRequireSoftwareRetry = { [weak self] in
            self?.retryWithSoftwareDecode()
        }
    }

    private func handleEngineError(_ message: String) {
        watchdog?.cancel()
        AppDebugLog.write("[Player] ERROR: \(message)")

        // 打开失败（如负载均衡节点返回坏数据）：先静默重试一次，通常换个节点即恢复
        if message.contains("文件或编码不受支持"), openRetryCount < 1 {
            openRetryCount += 1
            let position = max(currentTime, request.startAt)
            AppDebugLog.write("[Player] 打开失败，自动重试第 \(openRetryCount) 次 @ \(position)")
            showNotice("服务器数据异常，正在重试…")
            isLoading = true
            errorMessage = nil
            buildEngine(currentKind, at: position)
            startWatchdog()
            return
        }

        isLoading = false
        errorMessage = message.contains("文件或编码不受支持")
            ? "打开失败：服务器返回的数据异常，请稍后重试，或换一个节点/来源播放"
            : message
    }

    /// 运行时切换解码方式（VLC 内核）
    func switchDecodeMode(_ mode: PlaybackDecodeMode) {
        guard mode != decodeMode else { return }
        decodeMode = mode
        let position = max(currentTime, request.startAt)
        let kind: PlaybackEngineKind = currentKind
        isLoading = true
        errorMessage = nil
        AppDebugLog.write("[Player] 切换解码方式: \(mode.rawValue) @ \(position)")
        buildEngine(kind, at: position)
        startWatchdog()
        showNotice("解码方式：\(mode.title)")
    }

    /// 硬解失败：自动切换软解并续播
    func retryWithSoftwareDecode() {
        guard decodeMode != .software else { return }
        decodeMode = .software
        let position = max(currentTime, request.startAt)
        isLoading = true
        errorMessage = nil
        AppDebugLog.write("[Player] 硬解失败，自动切换软解 @ \(position)")
        showNotice("硬件解码失败，已切换为软件解码")
        buildEngine(currentKind, at: position)
        startWatchdog()
    }

    /// 重新加载当前内核
    func reload() {
        isLoading = true
        errorMessage = nil
        let position = max(currentTime, request.startAt)
        buildEngine(currentKind, at: position)
        startWatchdog()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let expected = engine
        watchdog = Task { @MainActor [weak self] in
            // 12 秒无画面：提前转储内核状态（不报错，仅供诊断）
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.engine === expected, self.currentTime < 0.5 {
                AppDebugLog.write("[Player] 12 秒无画面，转储内核状态")
                self.engine.debugDumpState()
            }
            // 45 秒无画面：报错并再次转储
            try? await Task.sleep(nanoseconds: 33_000_000_000)
            guard !Task.isCancelled, self.engine === expected, self.errorMessage == nil, self.currentTime < 0.5 else { return }
            self.engine.debugDumpState()
            self.handleEngineError("打开视频超时（45 秒无画面），可尝试切换软件解码或 VLC 内核")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        if isPlaying {
            engine.pause()
        } else {
            if didReachEnd {
                seek(to: 0)
                didReachEnd = false
            }
            engine.play()
            engine.setRate(playbackRate)
        }
    }

    func pause() {
        engine.pause()
    }

    func play() {
        engine.play()
        engine.setRate(playbackRate)
    }

    func setRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            engine.setRate(rate)
        }
    }

    func skip(_ seconds: Double) {
        let target = min(max(currentTime + seconds, 0), max(duration, 0))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let clamped = min(max(seconds, 0), upper)
        isSeeking = true
        seekTarget = clamped
        engine.seek(to: clamped)
        currentTime = clamped
        updateActiveCue()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.isSeeking = false
        }
    }

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    // MARK: - 字幕

    /// 远程来源的同名字幕：播放时拉取到本机缓存，再作为普通字幕加载
    private func fetchRemoteSubtitles() async {
        guard !request.remoteSubtitles.isEmpty else { return }
        for (index, descriptor) in request.remoteSubtitles.prefix(6).enumerated() {
            guard let response = try? await HTTPClient.request("GET",
                                                               url: descriptor.url,
                                                               headers: descriptor.headers,
                                                               timeout: 60) else { continue }
            guard let decoded = TextDecoding.decode(response.data),
                  !SubtitleParser.parse(text: decoded.text).isEmpty else { continue }

            let rawName = descriptor.title.isEmpty ? "远程字幕 \(index + 1)" : descriptor.title
            let destination = FileStore.uniqueDestination(for: rawName.sanitizedFileName, in: FileStore.subtitles)
            if let data = decoded.text.data(using: .utf8) {
                try? data.write(to: destination, options: .atomic)
            }
            addSubtitles([MediaFileRef(path: destination.path,
                                       name: destination.lastPathComponent,
                                       size: FileStore.size(of: destination))])
        }
    }

    func addSubtitles(_ files: [MediaFileRef]) {
        for file in files {
            let option = SubtitleOption(id: file.path, name: file.name, url: file.url)
            if !sidecarOptions.contains(where: { $0.id == option.id }) {
                sidecarOptions.append(option)
            }
        }
        refreshSubtitleOptions()
    }

    private func refreshAudioTracks() {
        audioTracks = engine.audioTracks()
        if let selected = selectedAudioID, !audioTracks.contains(where: { $0.id == selected }) {
            selectedAudioID = nil
        }
        videoTracks = engine.videoTracks()
        if let selected = selectedVideoID, !videoTracks.contains(where: { $0.id == selected }) {
            selectedVideoID = nil
        }
    }

    func setAspect(_ aspect: PlayerAspect) {
        self.aspect = aspect
        engine.setAspect(aspect)
    }

    func selectAudioTrack(_ id: String?) {
        selectedAudioID = id
        engine.selectAudioTrack(id)
    }

    func selectVideoTrack(_ id: String?) {
        selectedVideoID = id
        engine.selectVideoTrack(id)
    }

    private func refreshSubtitleOptions() {
        var options = sidecarOptions
        for track in engine.embeddedTracks() {
            if !options.contains(where: { $0.id == track.id }) {
                options.append(SubtitleOption(id: track.id, name: "内嵌 · \(track.name)", url: nil, isEmbedded: true))
            }
        }
        subtitleOptions = options
    }

    private func autoLoadSidecarSubtitle() {
        guard cues.isEmpty, let first = sidecarOptions.first else { return }
        selectSubtitle(first.id)
    }

    func selectSubtitle(_ id: String?) {
        selectedSubtitleID = id

        guard let id, let option = subtitleOptions.first(where: { $0.id == id }) else {
            cues = []
            activeCue = nil
            subtitleName = nil
            engine.selectEmbeddedTrack(nil)
            return
        }

        if option.isEmbedded {
            cues = []
            activeCue = nil
            subtitleName = option.name
            engine.selectEmbeddedTrack(option.id)
            return
        }

        engine.selectEmbeddedTrack(nil)
        guard let url = option.url, let parsed = SubtitleParser.parseFile(url: url) else {
            cues = []
            subtitleName = nil
            return
        }
        cues = parsed.cues
        subtitleName = option.name
        updateActiveCue()
    }

    /// 应用已保存在本机的字幕文件（来自在线搜索或字幕库）
    func applySubtitleFile(_ url: URL) {
        guard let parsed = SubtitleParser.parseFile(url: url) else {
            errorMessage = "无法解析该字幕文件"
            return
        }
        cues = parsed.cues
        subtitleName = url.lastPathComponent
        let option = SubtitleOption(id: "lib-\(url.path)", name: url.lastPathComponent, url: url)
        if !sidecarOptions.contains(where: { $0.url == url }) {
            sidecarOptions.append(option)
        }
        refreshSubtitleOptions()
        selectedSubtitleID = option.id
        delayMs = 0
        engine.selectEmbeddedTrack(nil)
        updateActiveCue()
    }

    func importSubtitle(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let parsed = SubtitleParser.parseFile(url: url) else {
            errorMessage = "无法解析该字幕文件"
            return
        }
        cues = parsed.cues
        subtitleName = url.lastPathComponent
        delayMs = 0
        engine.selectEmbeddedTrack(nil)

        let destination = FileStore.uniqueDestination(for: url.lastPathComponent, in: FileStore.subtitles)
        if let data = try? Data(contentsOf: url) {
            try? data.write(to: destination, options: .atomic)
        }
        let option = SubtitleOption(id: "imported-\(destination.path)", name: destination.lastPathComponent, url: destination)
        if !sidecarOptions.contains(where: { $0.name == option.name }) {
            sidecarOptions.append(option)
        }
        refreshSubtitleOptions()
        selectedSubtitleID = option.id
        updateActiveCue()
    }

    func setSubtitleDelay(_ milliseconds: Int) {
        delayMs = milliseconds
        updateActiveCue()
    }

    var subtitleDelay: Int { delayMs }

    private func updateActiveCue() {
        guard !cues.isEmpty else {
            if activeCue != nil { activeCue = nil }
            return
        }
        let time = currentTime - Double(delayMs) / 1000.0
        let cue = findCue(at: time)
        if cue?.id != activeCue?.id {
            activeCue = cue
        }
    }

    private func findCue(at time: Double) -> SubtitleCue? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if cue.start <= time {
                if time <= cue.end { return cue }
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return nil
    }

    // MARK: - 音频会话与锁屏

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            Log.error("音频会话配置失败", error)
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func saveProgressIfNeeded() {
        guard let media = request.media, currentTime > 5 else { return }
        NotificationCenter.default.post(name: .fmPlayerProgress,
                                        object: nil,
                                        userInfo: ["itemID": media.id, "seconds": currentTime])
    }

    private func updateNowPlaying(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlayingUpdate) > 1.0 else { return }
        lastNowPlayingUpdate = now

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = request.displayTitle
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}

extension Notification.Name {
    static let fmPlayerProgress = Notification.Name("fm.player.progress")
}
