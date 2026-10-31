import Foundation
import UIKit
import OpenGLES
import Darwin

#if canImport(Libmpv)
import Libmpv

// MARK: - 事件

private enum MPVEventPayload {
    case time(Double)
    case duration(Double)
    case paused(Bool)
    case buffering(Bool)
    case ended
    case fileLoaded
    case failure(String)
}

private func parseMPVEvent(_ event: mpv_event) -> MPVEventPayload? {
    if event.event_id == MPV_EVENT_FILE_LOADED { return .fileLoaded }
    if event.event_id == MPV_EVENT_END_FILE {
        if let data = event.data {
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            MPVDebugLog.write("END_FILE reason=(endFile.reason.rawValue)")
            if endFile.reason == MPV_END_FILE_REASON_ERROR {
                return .failure("MPV 播放失败：文件或编码不受支持")
            }
        }
        return .ended
    }
    if event.event_id == MPV_EVENT_LOG_MESSAGE, let data = event.data {
        let logEvent = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        let text = logEvent.text.map { String(cString: $0) } ?? ""
        let prefix = logEvent.prefix.map { String(cString: $0) } ?? ""
        let level = logEvent.level.map { String(cString: $0) } ?? ""
        MPVDebugLog.write("[mpv:\(level)] \(prefix) \(text)")
        return nil
    }
    guard event.event_id == MPV_EVENT_PROPERTY_CHANGE, let data = event.data else { return nil }
    let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
    guard let namePointer = property.name else { return nil }
    let name = String(cString: namePointer)
    switch name {
    case "time-pos":
        guard property.format == MPV_FORMAT_DOUBLE,
              let value = property.data?.assumingMemoryBound(to: Double.self).pointee else { return nil }
        return .time(value)
    case "duration":
        guard property.format == MPV_FORMAT_DOUBLE,
              let value = property.data?.assumingMemoryBound(to: Double.self).pointee else { return nil }
        return .duration(value)
    case "pause":
        guard property.format == MPV_FORMAT_FLAG,
              let value = property.data?.assumingMemoryBound(to: Int32.self).pointee else { return nil }
        return .paused(value != 0)
    case "paused-for-cache":
        guard property.format == MPV_FORMAT_FLAG,
              let value = property.data?.assumingMemoryBound(to: Int32.self).pointee else { return nil }
        return .buffering(value != 0)
    default:
        return nil
    }
}

private func mpvEventLoop(handle: OpaquePointer, emit: @escaping (MPVEventPayload) -> Void) {
    while true {
        guard let event = mpv_wait_event(handle, 0.3) else { continue }
        let value = event.pointee
        if value.event_id == MPV_EVENT_SHUTDOWN { break }
        if let payload = parseMPVEvent(value) { emit(payload) }
    }
}

private let mpvGetProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private let mpvRenderUpdate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    Task { @MainActor in
        Unmanaged<MPVPlayerEngine>.fromOpaque(context).takeUnretainedValue().renderIfNeeded()
    }
}

// MARK: - 渲染视图

final class MPVGLView: UIView {
    var onLayout: ((CGSize, CGFloat) -> Void)?
    var onWindowChange: (() -> Void)?

    override class var layerClass: AnyClass { CAEAGLLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        onLayout?(bounds.size, contentScaleFactor)
    }
}

// MARK: - 轨道与指标

private struct MPVTrackInfo {
    var id: Int
    var type: String
    var language: String
    var title: String
    var codec: String
    var external: Bool
}

private enum MPVMetrics {
    static func cacheSpeed(handle: OpaquePointer) -> Double {
        var value: Double = 0
        let result = withUnsafeMutablePointer(to: &value) { pointer -> Int32 in
            mpv_get_property(handle, "cache-speed", MPV_FORMAT_DOUBLE, pointer)
        }
        guard result >= 0, value.isFinite, value > 0 else { return 0 }
        return value
    }
}

// MARK: - MPV 内核

@MainActor
final class MPVPlayerEngine: NSObject, PlaybackEngine {
    let name = "MPV"
    var isNative: Bool { true }

    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onPlaybackState: ((Bool, Bool) -> Void)?
    var onTracks: (() -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var onSpeed: ((Double) -> Void)?
    var onRequireSoftwareRetry: (() -> Void)?

    private let decodeMode: PlaybackDecodeMode
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var eventLoopStarted = false
    private var eventLoopDone: DispatchSemaphore?
    private var isShuttingDown = false

    private let containerView = UIView()
    private let glView = MPVGLView()
    private let swDisplayView = UIView()
    private var renderAPI: RenderAPI = .gl
    private var isAttached = false
    private var frameRendered = false
    private var glContext: EAGLContext?
    private var framebuffer: GLuint = 0
    private var colorRenderbuffer: GLuint = 0
    private var bufferSize = CGSize.zero
    private var swContext: CGContext?
    private var swBuffer: UnsafeMutableRawPointer?
    private var swPixelSize = CGSize.zero
    private var swFallbackTask: Task<Void, Never>?
    private var aspectBuffer: UnsafeMutablePointer<CChar>?

    private var pendingSeek: Double = 0
    private var lastKnownTime: Double = 0
    private var isPaused = true
    private var didReportError = false
    private var currentKind: PlaybackEngineKind = .auto
    private let speedQueue = DispatchQueue(label: "fm.mpv.speed", qos: .utility)
    private var speedTimer: DispatchSourceTimer?

    private enum RenderAPI { case gl, sw }

    init(decode: PlaybackDecodeMode = .auto) {
        self.decodeMode = decode
        super.init()
        containerView.backgroundColor = .black
        swDisplayView.backgroundColor = .black
        swDisplayView.isHidden = true
        swDisplayView.layer.contentsGravity = .resizeAspect
        containerView.addSubview(swDisplayView)
        containerView.addSubview(glView)
        for subview in [glView, swDisplayView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: containerView.topAnchor),
                subview.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                subview.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
        glView.onLayout = { [weak self] size, scale in
            self?.handleLayout(size: size, scale: scale)
        }
        glView.onWindowChange = { [weak self] in
            self?.handleLayout(size: self?.glView.bounds.size ?? .zero,
                               scale: self?.glView.contentScaleFactor ?? 2)
        }
    }

    // MARK: - PlaybackEngine

    func load(_ descriptor: StreamDescriptor, startAt: Double, rate: Double) {
        MPVDebugLog.start()
        MPVDebugLog.write("=== load: (descriptor.url.absoluteString.prefix(120)) decode=(decodeMode.rawValue) ===")
        guard createMPVIfNeeded() else {
            MPVDebugLog.write("ERROR: mpv create/init failed")
            reportError("MPV 初始化失败")
            return
        }
        didReportError = false
        frameRendered = false
        pendingSeek = startAt
        attachIfNeeded()

        if descriptor.headers.isEmpty {
            setProperty("http-header-fields", "")
        } else {
            let fields = descriptor.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            setProperty("http-header-fields", fields)
        }
        setProperty("pause", "no")
        setProperty("speed", String(format: "%.2f", rate))
        let target = descriptor.url.isFileURL ? descriptor.url.path : descriptor.url.absoluteString
        MPVDebugLog.write("load: isFileURL=" + String(descriptor.url.isFileURL))
        let apiName = renderAPI == .gl ? "GL" : "SW"
        MPVDebugLog.write("renderAPI=" + apiName + " frameRendered=" + String(frameRendered))
        MPVDebugLog.write("loadfile: " + String(target.prefix(150)))
        startSpeedSampling()
    }

    func play() { setProperty("pause", "no") }
    func pause() { setProperty("pause", "yes") }

    func setRate(_ rate: Double) {
        setProperty("speed", String(format: "%.2f", rate))
    }

    func seek(to seconds: Double) {
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"])
    }

    func makeView() -> UIView { containerView }

    func teardown() {
        stopSpeedSampling()
        onSpeed?(0)
        swFallbackTask?.cancel()
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let handle {
            isShuttingDown = true
            command(["quit"])
            _ = eventLoopDone?.wait(timeout: .now() + 2)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        eventLoopStarted = false
        eventLoopDone = nil
        isShuttingDown = false
        MPVDebugLog.write("=== teardown ===")
        MPVDebugLog.stop()
        isAttached = false
        renderAPI = .gl
        frameRendered = false
        destroyFramebuffer()
        bufferSize = .zero
        glView.isHidden = false
        swDisplayView.isHidden = true
        glView.layer.contents = nil
        swDisplayView.layer.contents = nil
        if let swBuffer { free(swBuffer); self.swBuffer = nil }
        swContext = nil
        swPixelSize = .zero
        if let aspectBuffer { free(aspectBuffer); self.aspectBuffer = nil }
    }

    // MARK: - 轨道

    private struct MPVTrackInfo {
        var id: Int
        var type: String
        var language: String
        var title: String
        var codec: String
        var external: Bool
    }

    private func readTracks() -> [MPVTrackInfo] {
        guard let handle else { return [] }
        var node = mpv_node()
        let result = withUnsafeMutablePointer(to: &node) { pointer -> Int32 in
            mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, pointer)
        }
        defer { mpv_free_node_contents(&node) }
        guard result >= 0, node.format == MPV_FORMAT_NODE_ARRAY, let listPointer = node.u.list else { return [] }
        let list = listPointer.pointee
        guard let values = list.values else { return [] }
        var tracks: [MPVTrackInfo] = []
        for index in 0..<Int(list.num) {
            let item = values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let mapPointer = item.u.list else { continue }
            let map = mapPointer.pointee
            var info = MPVTrackInfo(id: 0, type: "", language: "", title: "", codec: "", external: false)
            for fieldIndex in 0..<Int(map.num) {
                guard let keyPointer = map.keys?[fieldIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = map.values[fieldIndex]
                switch key {
                case "id":
                    if value.format == MPV_FORMAT_INT64 { info.id = Int(value.u.int64) }
                case "type":
                    if value.format == MPV_FORMAT_STRING, let pointer = value.u.string { info.type = String(cString: pointer) }
                case "lang":
                    if value.format == MPV_FORMAT_STRING, let pointer = value.u.string { info.language = String(cString: pointer) }
                case "title":
                    if value.format == MPV_FORMAT_STRING, let pointer = value.u.string { info.title = String(cString: pointer) }
                case "codec":
                    if value.format == MPV_FORMAT_STRING, let pointer = value.u.string { info.codec = String(cString: pointer) }
                case "external":
                    if value.format == MPV_FORMAT_FLAG { info.external = value.u.flag != 0 }
                default: break
                }
            }
            tracks.append(info)
        }
        return tracks
    }

    func embeddedTracks() -> [PlaybackSubtitleTrack] {
        readTracks().filter { $0.type == "sub" && !$0.external }.map { item in
            let name = item.title.isEmpty ? (item.language.isEmpty ? "字幕 \(item.id)" : item.language) : item.title
            return PlaybackSubtitleTrack(id: "mpv-sub-\(item.id)", name: name)
        }
    }

    func selectEmbeddedTrack(_ id: String?) {
        guard let id, id.hasPrefix("mpv-sub-"), let trackID = Int32(id.dropFirst("mpv-sub-".count)) else {
            setProperty("sid", "no")
            return
        }
        setProperty("sid", String(trackID))
    }

    func audioTracks() -> [PlaybackAudioTrack] {
        readTracks().filter { $0.type == "audio" }.map { item in
            var name = item.title.isEmpty ? (item.language.isEmpty ? "音轨 \(item.id)" : item.language) : item.title
            if !item.codec.isEmpty { name += " · \(item.codec)" }
            return PlaybackAudioTrack(id: "mpv-aid-\(item.id)", name: name)
        }
    }

    func selectAudioTrack(_ id: String?) {
        guard let id, id.hasPrefix("mpv-aid-"), let trackID = Int32(id.dropFirst("mpv-aid-".count)) else {
            setProperty("aid", "auto")
            return
        }
        setProperty("aid", String(trackID))
    }

    func videoTracks() -> [PlaybackVideoTrack] {
        var index = 0
        return readTracks().filter { $0.type == "video" }.map { item in
            index += 1
            var name = item.title.isEmpty ? (item.language.isEmpty ? "视频 \(index)" : item.language) : item.title
            if !item.codec.isEmpty { name += " · \(item.codec)" }
            return PlaybackVideoTrack(id: "mpv-vid-\(item.id)", name: name)
        }
    }

    func selectVideoTrack(_ id: String?) {
        guard let id, id.hasPrefix("mpv-vid-"), let trackID = Int32(id.dropFirst("mpv-vid-".count)) else {
            setProperty("vid", "auto")
            return
        }
        setProperty("vid", String(trackID))
    }

    func setAspect(_ aspect: PlayerAspect) {
        switch aspect {
        case .auto:
            setProperty("video-aspect-override", "-1")
            setProperty("panscan", "0")
        case .fill:
            setProperty("video-aspect-override", "-1")
            setProperty("panscan", "1.0")
        case .stretch:
            let size = containerView.bounds.size
            guard size.width > 1, size.height > 1 else { return }
            setProperty("video-aspect-override", String(format: "%.4f", Double(size.width / size.height)))
            setProperty("panscan", "0")
        case .ratio16x9:
            setProperty("video-aspect-override", "16:9")
            setProperty("panscan", "0")
        case .ratio4x3:
            setProperty("video-aspect-override", "4:3")
            setProperty("panscan", "0")
        }
    }

    // MARK: - mpv 生命周期

    private func createMPVIfNeeded() -> Bool {
        if handle != nil { return true }
        let ctx = mpv_create()
        MPVDebugLog.write("mpv_create: ((ctx != nil))")
        guard let ctx else { return false }

        mpv_set_option_string(ctx, "vo", "libmpv")
        mpv_set_option_string(ctx, "config", "no")
        mpv_set_option_string(ctx, "terminal", "no")
        mpv_set_option_string(ctx, "msg-level", "all=warn")
        mpv_set_option_string(ctx, "sub-auto", "no")
        mpv_set_option_string(ctx, "sid", "no")
        mpv_set_option_string(ctx, "keep-open", "no")
        mpv_set_option_string(ctx, "input-default-bindings", "no")
        mpv_set_option_string(ctx, "input-vo-keyboard", "no")
        mpv_set_option_string(ctx, "osc", "no")
        mpv_set_option_string(ctx, "hwdec", decodeMode.mpvValue)
        MPVDebugLog.write("hwdec = (decodeMode.mpvValue)")
        mpv_set_option_string(ctx, "audio-client-name", "FMMedia")

        let initResult = mpv_initialize(ctx)
        MPVDebugLog.write("mpv_initialize result: ((initResult))")
        guard initResult >= 0 else {
            mpv_terminate_destroy(ctx)
            return false
        }
        handle = ctx

        mpv_observe_property(ctx, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_request_log_messages(ctx, "warn")
        startEventLoop(ctx)
        return true
    }

    private func startEventLoop(_ ctx: OpaquePointer) {
        guard !eventLoopStarted else { return }
        eventLoopStarted = true
        let done = DispatchSemaphore(value: 0)
        eventLoopDone = done
        let emit: (MPVEventPayload) -> Void = { [weak self] payload in
            Task { @MainActor in self?.handle(payload) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            mpvEventLoop(handle: ctx, emit: emit)
            done.signal()
        }
    }

    private func handle(_ payload: MPVEventPayload) {
        guard !isShuttingDown else { return }
        switch payload {
        case .time(let seconds):
            lastKnownTime = seconds
            onTime?(seconds)
        case .duration(let seconds):
            guard seconds > 0 else { return }
            onDuration?(seconds)
        case .paused(let paused):
            isPaused = paused
            onPlaybackState?(!paused, false)
        case .buffering(let buffering):
            onPlaybackState?(!isPaused, buffering)
        case .ended:
            onEnd?()
        case .fileLoaded:
            if pendingSeek > 1 {
                seek(to: pendingSeek)
                pendingSeek = 0
            }
            startFallbackCheck()
            onPlaybackState?(true, false)
        case .failure(let message):
            reportError(message)
        }
    }

    private func reportError(_ message: String) {
        guard !didReportError else { return }
        didReportError = true
        onError?(message)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let handle, !isShuttingDown else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        let allocated = arguments.map { strdup($0) }
        var pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        defer {
            for pointer in allocated {
                if let pointer { free(pointer) }
            }
        }
        mpv_command(handle, &pointers)
    }

    // MARK: - 渲染

    private func attachIfNeeded() {
        guard !isAttached, let mpvHandle = handle else { return }
        createRenderContext(for: mpvHandle, api: renderAPI)
        isAttached = true
    }

    private func createRenderContext(for handle: OpaquePointer, api: RenderAPI) {
        switch api {
        case .gl:
            attachGLRenderContext(handle: handle)
        case .sw:
            attachSWRenderContext(handle: handle)
        }
    }

    private func attachGLRenderContext(handle: OpaquePointer) {
        MPVDebugLog.write("attachGLRenderContext: creating EAGLContext")
        guard let eagl = EAGLContext(api: .openGLES2) else {
            MPVDebugLog.write("ERROR: EAGLContext creation failed")
            switchToSWRender()
            return
        }
        EAGLContext.setCurrent(eagl)
        glContext = eagl

        if let layer = glView.layer as? CAEAGLLayer {
            layer.isOpaque = true
            layer.drawableProperties = [
                kEAGLDrawablePropertyRetainedBacking: false,
                kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
            ]
        }

        var glInit = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress,
                                            get_proc_address_ctx: nil)
        var advancedControl: Int32 = 1
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { if let apiType { free(apiType) } }

        withUnsafeMutablePointer(to: &glInit) { glPointer in
            withUnsafeMutablePointer(to: &advancedControl) { advancedPointer in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType.map { UnsafeMutableRawPointer($0) }),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advancedPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                var context: OpaquePointer?
                let result = mpv_render_context_create(&context, handle, &params)
                MPVDebugLog.write("mpv_render_context_create(GL): result=(result) context=(context != nil)")
                guard result >= 0, let context else {
                    switchToSWRender()
                    return
                }
                renderContext = context
                mpv_render_context_set_update_callback(context, mpvRenderUpdate,
                                                       Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private func attachSWRenderContext(handle: OpaquePointer) {
        MPVDebugLog.write("attachSWRenderContext: creating SW context")
        var apiType = strdup(MPV_RENDER_API_TYPE_SW)
        defer { if let apiType { free(apiType) } }
        withUnsafeMutablePointer(to: &apiType) { apiPointer in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            var context: OpaquePointer?
            let result = mpv_render_context_create(&context, handle, &params)
            MPVDebugLog.write("mpv_render_context_create(SW): result=(result)")
            guard result >= 0, let context else {
                reportError("MPV 软件渲染初始化失败")
                return
            }
            renderContext = context
            mpv_render_context_set_update_callback(context, mpvRenderUpdate,
                                                   Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func handleLayout(size: CGSize, scale: CGFloat) {
        guard handle != nil, containerView.window != nil, size.width > 1, size.height > 1 else { return }
        if renderContext == nil { attachIfNeeded() }
        guard renderContext != nil else { return }

        if renderAPI == .gl {
            let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
            if framebuffer == 0 || abs(pixelSize.width - bufferSize.width) > 1 || abs(pixelSize.height - bufferSize.height) > 1 {
                buildFramebuffer(size: size, scale: scale)
                renderFrame()
            }
        } else {
            swRender()
        }
    }

    private func buildFramebuffer(size: CGSize, scale: CGFloat) {
        guard let glContext else { return }
        EAGLContext.setCurrent(glContext)
        destroyFramebuffer()

        guard let layer = glView.layer as? CAEAGLLayer else { return }
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glGenRenderbuffers(1, &colorRenderbuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        _ = glContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorRenderbuffer)

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            Log.error("MPV 帧缓冲不完整 status=\(status)")
            destroyFramebuffer()
            return
        }
        bufferSize = CGSize(width: size.width * scale, height: size.height * scale)
        glViewport(0, 0, GLsizei(bufferSize.width), GLsizei(bufferSize.height))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        _ = glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    private func destroyFramebuffer() {
        if framebuffer != 0 {
            glDeleteFramebuffers(1, &framebuffer)
            framebuffer = 0
        }
        if colorRenderbuffer != 0 {
            glDeleteRenderbuffers(1, &colorRenderbuffer)
            colorRenderbuffer = 0
        }
    }

    func renderIfNeeded() {
        guard let renderContext, containerView.window != nil else { return }
        if renderAPI == .sw {
            swRender()
            return
        }
        guard framebuffer != 0 else { return }
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        renderFrame()
    }

    private func renderFrame() {
        guard glView.window != nil else { return }
        guard let renderContext, let glContext, framebuffer != 0,
              bufferSize.width > 1, bufferSize.height > 1 else { return }
        EAGLContext.setCurrent(glContext)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer),
                                 w: Int32(bufferSize.width),
                                 h: Int32(bufferSize.height),
                                 internal_format: 0)
        var flip: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }

        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        _ = glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
        mpv_render_context_report_swap(renderContext)
        if !frameRendered { MPVDebugLog.write("GL first frame rendered") }
        frameRendered = true
    }

    // MARK: - SW 软件渲染兜底

    private func startFallbackCheck() {
        swFallbackTask?.cancel()
        guard renderAPI == .gl else { return }
        swFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.renderAPI == .gl, !self.frameRendered else { return }
            self.switchToSWRender()
        }
    }

    private func switchToSWRender() {
        MPVDebugLog.write("switchToSWRender: frameRendered=(frameRendered)")
        guard renderAPI == .gl else { return }
        renderAPI = .sw
        Log.info("MPV：GL 渲染无画面，切换为软件渲染")
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        destroyFramebuffer()
        glContext = nil
        glView.isHidden = true
        swDisplayView.isHidden = false
        frameRendered = false
        if let handle {
            attachSWRenderContext(handle: handle)
        }
        isAttached = true
        if lastKnownTime > 1 { seek(to: lastKnownTime) }
        startFallbackCheck()
    }


    private func swRender() {
        guard let renderContext else { return }
        let scale = min(UIScreen.main.scale, 2)
        let width = max(Int(containerView.bounds.width * scale), 2)
        let height = max(Int(containerView.bounds.height * scale), 2)
        ensureSWBuffer(width: width, height: height)
        guard let swContext, let swBuffer else { return }

        // 手工构造 mpv_render_param 数组（SW_SIZE / SW_STRIDE / SW_POINTER / SW_FORMAT）
        // 避免依赖可能未导出的 mpv_sw_size 类型
        let w = Int32(max(swPixelSize.width, 2))
        let h = Int32(max(swPixelSize.height, 2))
        let strideValue = Int32(w * 4)
        var sizeStruct = (w, h)          // (int, int) = 8 bytes
        var strideStruct = (strideValue) // int = 4 bytes
        var formatStr = strdup("rgba")
        defer { if let formatStr { free(UnsafeMutableRawPointer(formatStr)) } }
        var pointerValue = UnsafeMutableRawPointer(swBuffer)

        withUnsafeMutablePointer(to: &sizeStruct) { sizePtr in
            withUnsafeMutablePointer(to: &strideStruct) { stridePtr in
                withUnsafeMutablePointer(to: &pointerValue) { dataPtr in
                    withUnsafeMutablePointer(to: &formatStr) { formatPtr in
                        var params: [mpv_render_param] = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: UnsafeMutableRawPointer(dataPtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                        ]
                        mpv_render_context_render(renderContext, &params)
                    }
                }
            }
        }
        frameRendered = true

        if let image = swContext.makeImage() {
            swDisplayView.layer.contents = image
            if !frameRendered { MPVDebugLog.write("SW first frame rendered, size=(swWidth)x(swHeight)") }
        }
    }

    private func ensureSWBuffer(width: Int, height: Int) {
        guard swPixelSize.width != CGFloat(width) || swPixelSize.height != CGFloat(height) else { return }
        swPixelSize = CGSize(width: width, height: height)
        if let swBuffer { free(swBuffer); self.swBuffer = nil }
        let bytesPerRow = width * 4
        swBuffer = malloc(bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        swContext = CGContext(data: swBuffer,
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - 速度采样

    private func startSpeedSampling() {
        guard speedTimer == nil, let handle else { return }
        let timer = DispatchSource.makeTimerSource(queue: speedQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        let emit: (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.onSpeed?(value) }
        }
        timer.setEventHandler {
            emit(MPVMetrics.cacheSpeed(handle: handle))
        }
        timer.resume()
        speedTimer = timer
    }

    private func stopSpeedSampling() {
        speedTimer?.cancel()
        speedTimer = nil
        speedQueue.sync {}
    }
}

#endif
