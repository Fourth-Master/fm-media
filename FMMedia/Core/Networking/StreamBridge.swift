import Foundation
import Network
#if canImport(Libmpv)
import Libmpv
#endif

// MARK: - 桥接速度计（线程安全）

/// 聚合滑动窗口速度（字节/秒）：actor 内写入，网速显示线程读取
final class BridgeSpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Double, bytes: Int)] = []

    func record(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        samples.append((now, bytes))
        while !samples.isEmpty, samples.count > 128 || now - samples[0].time > 8 {
            samples.removeFirst()
        }
    }

    func speed() -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        samples.removeAll { now - $0.time > 8 }
        guard samples.count >= 2 else { return 0 }
        let total = samples.reduce(0) { $0 + $1.bytes }
        let span = now - samples[0].time
        return span > 0.3 ? Double(total) / span : 0
    }
}

// MARK: - 流文件下载器（按需阻塞读取 + 磁盘段缓存）

/// 每个远端流一个实例（猫头鹰同思路的"按需阻塞读取"）：
/// - 稀疏临时文件做段缓存（2MB/段，写穿磁盘，内存占用≈0）
/// - mpv 的读请求命中已下载段 → 从磁盘即时返回
///   未命中 → 实时发起 Range 拉取该段（0.1-0.3s/段），响应挂起等待，永不返回空洞
/// - 音视频交错距离再大也只是"多几次按需读取"，数据永远正确
/// - 预取：每个读取位置向前 1-2 段轻量预取，并发全局限流防触发服务器节流
actor StreamFileFetcher {
    static let segmentSize: Int64 = 2 * 1024 * 1024
    /// 浏览器 UA：部分服务器/WAF 拦截客户端 UA
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"

    let meter = BridgeSpeedMeter()
    let url: URL
    let headers: [String: String]
    let fileURL: URL
    let totalBytes: Int64

    private final class Segment {
        var done = false
        var errorMessage: String?
    }

    private var segments: [Int: Segment] = [:]
    private var inflight: Set<Int> = []
    private var inflightTasks: [Int: Task<Void, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var readers: [Reader] = []
    private var cancelled = false
    private var lastSpeedLogAt = Date().timeIntervalSinceReferenceDate
    private var connectionCount = 0
    /// 预取并发上限；按需读取（mpv 正在等的位置）不受此限，始终立即启动
    private let maxPrefetchInflight = 4

    /// 读取位置追踪（驱动 prefetchAround）；stream_cb 与 HTTP 泵共用
    final class Reader {
        var servedSegment: Int
        init(servedSegment: Int) { self.servedSegment = servedSegment }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config)
    }()

    init(url: URL, headers: [String: String], totalBytes: Int64, fileURL: URL) {
        self.url = url
        self.headers = headers
        self.totalBytes = totalBytes
        self.fileURL = fileURL
        // forUpdating = O_RDWR（forWritingTo 只写，读会抛 ObjC 异常崩溃）
        self.fileHandle = try? FileHandle(forUpdating: fileURL)
    }

    private var fileHandle: FileHandle?

    func cancel() {
        cancelled = true
        for task in inflightTasks.values { task.cancel() }
        inflightTasks.removeAll()
        // 断开预取来源：stream_cb 模式下 reader 要等 mpv close 才注销，
        // 不先清空的话 fetchSegment 的 defer→prefetchAround 会无限自续 spawn 任务
        readers.removeAll()
        wakeAll()
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 请求服务

    /// 服务一个 mpv 请求：回 206 头后从 rawStart 顺序泵数据到 rawEnd
    func serve(connection: NWConnection, rawStart: Int64, rawEnd: Int64?) async {
        guard !cancelled else {
            Self.sendSimple(connection, status: "502 Bad Gateway")
            return
        }
        var end = rawEnd ?? (totalBytes - 1)
        if end >= totalBytes { end = totalBytes - 1 }
        guard rawStart >= 0, rawStart <= end else {
            Self.sendSimple(connection, status: "416 Range Not Satisfiable")
            return
        }
        connectionCount += 1
        if connectionCount <= 8 || connectionCount % 200 == 0 {
            AppDebugLog.write("[Bridge] 连接#\(connectionCount) offset=\(rawStart)")
        }
        let reader = Reader(servedSegment: Int(rawStart / Self.segmentSize))
        readers.append(reader)
        defer {
            readers.removeAll { $0 === reader }
        }

        let head = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(end - rawStart + 1)\r\n"
            + "Content-Range: bytes \(rawStart)-\(end)/\(totalBytes)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Connection: close\r\n\r\n"
        if let headError = await Self.sendRaw(connection, data: Data(head.utf8)) {
            AppDebugLog.write("[Bridge] 泵#\(connectionCount)响应头发送失败: \(headError)")
            connection.cancel()
            return
        }

        var offset = rawStart
        while offset <= end, !cancelled, !Task.isCancelled {
            guard let chunk = await readSlice(reader, at: offset, maxLength: 256 * 1024), !chunk.isEmpty else {
                if !cancelled {
                    AppDebugLog.write("[Bridge] 泵#\(connectionCount)结束@\(offset) 原因=数据源失败")
                }
                break
            }
            if let sendError = await Self.sendRaw(connection, data: chunk) {
                AppDebugLog.write("[Bridge] 泵#\(connectionCount)结束@\(offset) 原因=发送失败: \(sendError)")
                break
            }
            offset += Int64(chunk.count)
        }
        if Task.isCancelled {
            AppDebugLog.write("[Bridge] 泵#\(connectionCount)取消@\(offset)（对端关闭/seek）")
        }
        connection.cancel()
    }

    // MARK: 按需读取

    /// 读取指定偏移；段未就绪时实时拉取（响应挂起等待），永不返回空洞数据
    private func readSlice(_ reader: Reader, at offset: Int64, maxLength: Int) async -> Data? {
        guard !cancelled, let handle = fileHandle else { return nil }
        let segIdx = Int(offset / Self.segmentSize)
        let segOffset = Int(offset % Self.segmentSize)
        if segIdx != reader.servedSegment {
            reader.servedSegment = segIdx
        }
        var resets = 0
        while !cancelled {
            guard let seg = segments[segIdx] else {
                startFetch(segIdx, onDemand: true)
                await waitForSegment(segIdx)
                continue
            }
            if seg.done { break }
            if let errorMessage = seg.errorMessage {
                // 失败恢复：重置重拉；同段最多 2 轮，仍失败断流交给 mpv 重连
                guard resets < 2 else {
                    AppDebugLog.write("[Bridge] 段#\(segIdx) 重拉\(resets)轮仍失败: \(errorMessage)")
                    return nil
                }
                resets += 1
                seg.errorMessage = nil
                startFetch(segIdx, onDemand: true)
                await waitForSegment(segIdx)
                continue
            }
            // 孤儿段检测：被取消后无人负责 → 重新启动
            if !inflight.contains(segIdx) {
                startFetch(segIdx, onDemand: true)
            }
            await waitForSegment(segIdx)
        }
        guard !cancelled, let seg = segments[segIdx], seg.done else { return nil }
        let segEnd = min(Int64(segIdx + 1) * Self.segmentSize, totalBytes)
        let readLen = Int(min(Int64(maxLength), segEnd - offset))
        guard readLen > 0 else { return nil }
        handle.seek(toFileOffset: UInt64(offset))
        return handle.readData(ofLength: readLen)
    }

    private func waitForSegment(_ idx: Int) async {
        // cancel 已发生时直接返回：否则注册的 continuation 无人 resume，
        // readSync 的信号量等待会永久挂起 mpv 线程 → 看门狗杀进程
        guard !cancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[idx, default: []].append(continuation)
        }
    }

    // MARK: stream_cb 读取入口

    /// 为一个 stream_cb 打开的流实例注册预取追踪 reader（open 回调时调用一次）
    func makeReader(at segment: Int) -> Reader {
        let reader = Reader(servedSegment: segment)
        readers.append(reader)
        return reader
    }

    /// stream_cb 流关闭时注销 reader
    func dropReader(_ reader: Reader) {
        readers.removeAll { $0 === reader }
    }

    /// stream_cb 读取：与 HTTP 泵同一套按需阻塞读取（段未就绪实时拉取，永不返回空洞）
    func readSliceForCB(_ reader: Reader, at offset: Int64, maxLength: Int) async -> Data? {
        await readSlice(reader, at: offset, maxLength: maxLength)
    }

    // MARK: 段获取

    /// 启动一段拉取（onDemand = mpv 正在等待的位置，绕过预取并发限制立即启动）
    private func startFetch(_ idx: Int, onDemand: Bool) {
        guard !cancelled else { return }
        if let seg = segments[idx], seg.done || seg.errorMessage != nil { return }
        if inflight.contains(idx) { return }
        if !onDemand, inflight.count >= maxPrefetchInflight { return }
        let seg: Segment
        if let existing = segments[idx] {
            seg = existing
        } else {
            seg = Segment()
            segments[idx] = seg
        }
        inflight.insert(idx)
        let task = Task { await self.fetchSegment(idx, seg) }
        inflightTasks[idx] = task
    }

    /// 拉取一段：整段 data(for:)（2MB @15MB/s ≈ 0.15s），严格校验后写盘对应偏移
    private func fetchSegment(_ idx: Int, _ seg: Segment) async {
        defer {
            inflight.remove(idx)
            inflightTasks.removeValue(forKey: idx)
            wake(idx)
            prefetchAround()
        }
        guard !cancelled else { return }
        let start = Int64(idx) * Self.segmentSize
        let end = min(start + Self.segmentSize, totalBytes) - 1
        guard start <= end else {
            seg.done = true
            wake(idx)
            return
        }
        var attempt = 0
        while attempt < 3, !cancelled, !Task.isCancelled {
            attempt += 1
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                if cancelled { return }
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                applyHeaders(to: &request)
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (data, response) = try await Self.session.data(for: request)
                let expected = Int(end - start + 1)
                // 严格校验：必须 206 且长度精确（防节点忽略 Range 返回错位数据 → 花屏）
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 206, data.count == expected else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    AppDebugLog.write("[Bridge] 段#\(idx) 响应异常 status=\(status) len=\(data.count) expect=\(expected)")
                    throw URLError(.badServerResponse)
                }
                guard let handle = fileHandle else { return }
                handle.seek(toFileOffset: UInt64(start))
                try handle.write(contentsOf: data)
                meter.record(data.count)
                seg.done = true
                wake(idx)
                logSpeedIfNeeded(speed: meter.speed())
                return
            } catch {
                if cancelled || Task.isCancelled { return }
                AppDebugLog.write("[Bridge] 段#\(idx) 第\(attempt)次失败: \(error.localizedDescription)")
            }
        }
        seg.errorMessage = "attempts exhausted"
        wake(idx)
    }

    /// 位置预取：每个读取位置向前补 16 段（32MB）。
    /// demuxer 在坏交错封装上会高频交替读取两个相距 66MB+ 的位置，
    /// 每个位置有 32MB 缓冲才不会每 10-50KB 就跳区（每次跳区 = 关连接重开，
    /// 高频跳区会触发服务器节流 → 段获取失败 → 泵中断 → 花屏）
    private func prefetchAround() {
        guard !cancelled else { return }
        for reader in readers {
            for ahead in 1...16 {
                startFetch(reader.servedSegment + ahead, onDemand: false)
            }
        }
    }

    private func wake(_ idx: Int) {
        guard let list = waiters.removeValue(forKey: idx) else { return }
        list.forEach { $0.resume() }
    }

    private func wakeAll() {
        for list in waiters.values {
            list.forEach { $0.resume() }
        }
        waiters.removeAll()
    }

    // MARK: 工具

    private func logSpeedIfNeeded(speed: Double) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSpeedLogAt >= 5 else { return }
        lastSpeedLogAt = now
        AppDebugLog.write("[Bridge] 下载 \(String(format: "%.2f", speed / 1_000_000))MB/s（缓存 \(segments.values.filter { $0.done }.count) 段）")
    }

    nonisolated static func sendRaw(_ connection: NWConnection, data: Data) async -> String? {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error?.localizedDescription)
            })
        }
    }

    nonisolated static func sendSimple(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
    }
}

// MARK: - 本地桥接服务器

/// mpv 从 127.0.0.1 取流，桥按需从网络拉取并缓存到稀疏磁盘文件。
/// register/localURL/unregister 仅主线程调用（播放引擎侧保证），speed 允许后台线程读。
final class StreamBridge {
    static let shared = StreamBridge()

    private var listener: NWListener?
    private var port: UInt16?
    private var nextID: Int64 = 1

    private let streamsLock = NSLock()
    private var streams: [Int64: StreamFileFetcher] = [:]

    private let queue = DispatchQueue(label: "fmmedia.streambridge", qos: .userInitiated)

    private init() {}

    // MARK: 注册表

    /// 注册远端流；服务器启动失败返回 nil（调用方回退 mpv 直连）
    func register(url: URL, headers: [String: String], totalBytes: Int64?) -> Int64? {
        guard ensureStarted(), let total = totalBytes, total > 0 else { return nil }
        let id = nextID
        nextID += 1
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmstream-\(id)-\(Int(total)).bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            try? handle.truncate(atOffset: UInt64(total))   // 稀疏文件：逻辑长度立即到位
            try? handle.close()
        }
        let fetcher = StreamFileFetcher(url: url, headers: headers, totalBytes: total, fileURL: fileURL)
        streamsLock.lock()
        streams[id] = fetcher
        streamsLock.unlock()
        let headerNames = headers.keys.joined(separator: ",")
        AppDebugLog.write("[Bridge] 注册流#\(id): \(url.absoluteString.prefix(100)) total=\(total)（按需阻塞读取）")
        return id
    }

    func localURL(for id: Int64) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/s/\(id)")
    }

    func unregister(_ id: Int64) {
        streamsLock.lock()
        let stream = streams.removeValue(forKey: id)
        streamsLock.unlock()
        contextLock.lock()
        let ctx = streamContexts.removeValue(forKey: id)
        contextLock.unlock()
        // 先关上下文（排空在途读），再取消 actor——mpv terminate 等待 close 回调
        // 完成后才退出，此顺序保证阻塞中的 read 有路可醒
        ctx?.closeSync()
        if let stream {
            AppDebugLog.write("[Bridge] 注销流#\(id)（清理临时文件）")
            Task { await stream.cancel() }
        }
    }

    /// 下载速度（字节/秒），供网速显示
    func speed(for id: Int64) -> Double {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return streams[id]?.meter.speed() ?? 0
    }

    /// stream_cb open 回调按 ID 查找流
    func fetcher(for id: Int64) -> StreamFileFetcher? {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return streams[id]
    }

    // MARK: stream_cb 上下文注册表
    // cookie 只存流 ID，StreamContext 存注册表持强引用：
    // mpv terminate 与阻塞中 read 回调的竞态下对象不会被提前释放（闪退根因）

    private let contextLock = NSLock()
    private var streamContexts: [Int64: StreamContext] = [:]

    /// open 回调：为流#id 创建上下文；流已注销返回 nil
    func makeStreamContext(id: Int64) -> StreamContext? {
        streamsLock.lock()
        let fetcher = streams[id]
        streamsLock.unlock()
        guard let fetcher else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = StreamCBOpenBox()
        Task {
            let reader = await fetcher.makeReader(at: 0)
            box.context = StreamContext(bridge: self, streamID: id,
                                        size: fetcher.totalBytes, reader: reader)
            semaphore.signal()
        }
        semaphore.wait()
        guard let ctx = box.context else { return nil }
        contextLock.lock()
        streamContexts[id] = ctx
        contextLock.unlock()
        return ctx
    }

    /// read/seek/size 回调查找（拿强引用，保证回调期间对象存活）
    func streamContext(for id: Int64) -> StreamContext? {
        contextLock.lock(); defer { contextLock.unlock() }
        return streamContexts[id]
    }

    /// close 回调：从注册表移除并排空在途读，此后对象才释放
    func closeStreamContext(_ id: Int64) {
        contextLock.lock()
        let ctx = streamContexts.removeValue(forKey: id)
        contextLock.unlock()
        ctx?.closeSync()
    }

    // MARK: 监听

    private func ensureStarted() -> Bool {
        if port != nil { return true }
        let params = NWParameters.tcp
        // 绑定 loopback：不触发 iOS 本地网络权限，也避免暴露端口到局域网
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else {
            AppDebugLog.write("[Bridge] NWListener 创建失败")
            return false
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                AppDebugLog.write("[Bridge] 监听失败: \(error)")
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        guard let boundPort = port, boundPort > 0 else {
            listener.cancel()
            AppDebugLog.write("[Bridge] 本地监听启动失败，回退 mpv 直连")
            return false
        }
        self.listener = listener
        AppDebugLog.write("[Bridge] 已启动 127.0.0.1:\(boundPort)")
        return true
    }

    // MARK: 连接处理

    private final class RequestBox {
        let connection: NWConnection
        var buffer = Data()
        var task: Task<Void, Never>?

        init(connection: NWConnection) { self.connection = connection }
    }

    private func handle(_ connection: NWConnection) {
        let box = RequestBox(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHead(box)
            case .failed, .cancelled:
                box.task?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHead(_ box: RequestBox) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { box.buffer.append(data) }
            if let text = String(data: box.buffer, encoding: .utf8),
               let range = text.range(of: "\r\n\r\n") {
                let head = String(text[..<range.lowerBound])
                box.buffer.removeAll(keepingCapacity: false)
                self.dispatch(box, head: head)
            } else if error != nil || isComplete || box.buffer.count > 32 * 1024 {
                box.connection.cancel()
            } else {
                self.receiveHead(box)
            }
        }
    }

    private func dispatch(_ box: RequestBox, head: String) {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            StreamFileFetcher.sendSimple(box.connection, status: "400 Bad Request")
            return
        }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else {
            StreamFileFetcher.sendSimple(box.connection, status: "400 Bad Request")
            return
        }
        let path = String(parts[1])
        guard path.hasPrefix("/s/"), let id = Int64(path.dropFirst(3)) else {
            StreamFileFetcher.sendSimple(box.connection, status: "404 Not Found")
            return
        }
        var start: Int64 = 0
        var end: Int64?
        for line in lines where line.lowercased().hasPrefix("range:") {
            let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bytes=") {
                let comps = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                if let first = comps.first, let parsed = Int64(first) { start = parsed }
                if comps.count > 1, let parsed = Int64(comps[1]) { end = parsed }
            }
            break
        }
        streamsLock.lock()
        let stream = streams[id]
        streamsLock.unlock()
        guard let stream else {
            StreamFileFetcher.sendSimple(box.connection, status: "404 Not Found")
            return
        }
        box.task = Task { await stream.serve(connection: box.connection, rawStart: start, rawEnd: end) }
    }
}

// MARK: - mpv stream_cb 自定义协议（fm://）

/// stream_cb 打开的流实例。cookie 不携带对象指针——只放流 ID，
/// 回调按 ID 到 StreamBridge 注册表查强引用：mpv terminate 时
/// 解复用线程可能仍阻塞在 read 的信号量等待里，对象指针会被
/// close 回调释放造成 use-after-free（1.8.68/69 滑动快进闪退根因）；
/// ID 查表 + close 前排空在途读彻底消除该竞态。
final class StreamContext: @unchecked Sendable {
    private let bridge: StreamBridge
    let streamID: Int64
    private let size: Int64
    private let reader: StreamFileFetcher.Reader
    private let lock = NSLock()
    private var offset: Int64 = 0
    /// 在途读计数：close 必须等其归零（mpv 线程仍阻塞在 read 信号量上时）
    private var inflightReads = 0
    private var closed = false

    init(bridge: StreamBridge, streamID: Int64, size: Int64, reader: StreamFileFetcher.Reader) {
        self.bridge = bridge
        self.streamID = streamID
        self.size = size
        self.reader = reader
    }

    /// 返回读取字节数；0 = EOF；<0 = IO 错误
    func readSync(buf: UnsafeMutableRawPointer?, maxBytes: Int) -> Int64 {
        guard let buf, maxBytes > 0 else { return 0 }
        lock.lock()
        if closed {
            lock.unlock()
            return -1
        }
        let at = offset
        inflightReads += 1
        lock.unlock()
        defer {
            lock.lock()
            inflightReads -= 1
            lock.unlock()
        }
        guard at < size else { return 0 }
        // 单次最多 1MB：mpv 的 stream buffer 可能很大，避免每次回调分配整块内存
        let want = min(maxBytes, 1024 * 1024)

        // 按需阻塞读取：段未就绪时实时拉取并挂起 mpv 线程（宁可停顿，不返回坏数据）。
        // 重试窗口 2s：瞬时报错（429/超时）靠段内 3 次重试 × 2 轮重置吸收，
        // 这里只兜底即时失败；teardown 等待排空最多也只耗 2s
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let bridge = self.bridge
        let id = self.streamID
        let reader = self.reader
        Task {
            var data: Data?
            var attempts = 0
            while attempts < 5 {
                attempts += 1
                guard let fetcher = bridge.fetcher(for: id) else { break }   // 已注销
                data = await fetcher.readSliceForCB(reader, at: at, maxLength: want)
                if data != nil { break }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            box.data = data
            semaphore.signal()
        }
        semaphore.wait()
        guard let data = box.data, !data.isEmpty else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buf, base, min(data.count, maxBytes)) }
        }
        offset = at + Int64(data.count)
        return Int64(data.count)
    }

    /// seek 到绝对偏移，返回实际生效的偏移（<0 = 失败）
    func seekSync(_ target: Int64) -> Int64 {
        let applied = max(0, min(target, size))
        lock.lock()
        offset = applied
        lock.unlock()
        return applied
    }

    var fileSize: Int64 { size }

    /// close 回调：注销 reader 并排空在途读（mpv 线程可能仍阻塞在 read 的
    /// 信号量等待里），排空后才允许释放——杜绝 use-after-free
    func closeSync() {
        lock.lock()
        closed = true
        lock.unlock()
        let bridge = self.bridge
        let reader = self.reader
        Task { await bridge.fetcher(for: streamID)?.dropReader(reader) }
        // 在途读持有的是本对象引用（非 cookie 指针），等待其醒来即可安全释放
        for _ in 0..<80 {
            lock.lock()
            let remaining = inflightReads
            lock.unlock()
            if remaining == 0 { break }
            usleep(50_000)   // 50ms × 80 = 最多 4s
        }
    }

    private final class ResultBox { var data: Data? }
}

private final class StreamCBOpenBox { var context: StreamContext? }

#if canImport(Libmpv)
// cookie 只存流 ID：UnsafeMutableRawPointer ←→ Int64 位模式互换（64 位平台同宽无损）
private func streamID(fromCookie cookie: UnsafeMutableRawPointer) -> Int64 {
    Int64(bitPattern: UInt64(UInt(bitPattern: cookie)))
}

// stream_cb 回调（C 函数指针，无捕获）
private let streamCBRead: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, UInt64) -> Int64 = { cookie, buf, nbytes in
    guard let cookie, let buf, nbytes > 0, nbytes <= UInt64(Int.max) else { return 0 }
    let id = streamID(fromCookie: cookie)
    guard let ctx = StreamBridge.shared.streamContext(for: id) else { return -1 }
    return ctx.readSync(buf: buf, maxBytes: Int(nbytes))
}

private let streamCBSeek: @convention(c) (UnsafeMutableRawPointer?, Int64) -> Int64 = { cookie, target in
    guard let cookie else { return -1 }
    guard let ctx = StreamBridge.shared.streamContext(for: streamID(fromCookie: cookie)) else { return -1 }
    return ctx.seekSync(target)
}

private let streamCBSize: @convention(c) (UnsafeMutableRawPointer?) -> Int64 = { cookie in
    guard let cookie else { return 0 }
    return StreamBridge.shared.streamContext(for: streamID(fromCookie: cookie))?.fileSize ?? 0
}

private let streamCBClose: @convention(c) (UnsafeMutableRawPointer?) -> Void = { cookie in
    guard let cookie else { return }
    StreamBridge.shared.closeStreamContext(streamID(fromCookie: cookie))
}

private let streamCBOpen: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<mpv_stream_cb_info>?) -> Int32 = { userData, uri, info in
    let failed = Int32(-13)   // MPV_ERROR_LOADING_FAILED
    guard let info else { return failed }
    let uriText = uri.map { String(cString: $0) } ?? ""
    guard uriText.hasPrefix("fm://"), let id = Int64(uriText.dropFirst(5)) else {
        AppDebugLog.write("[Bridge] stream_cb open 无法解析: \(uriText)")
        return failed
    }
    // cookie 只存流 ID；StreamContext 存入注册表持有强引用，
    // close 回调从注册表移除并排空在途读后释放
    guard let ctx = StreamBridge.shared.makeStreamContext(id: id) else {
        AppDebugLog.write("[Bridge] stream_cb open 未找到流#\(id)")
        return failed
    }
    AppDebugLog.write("[Bridge] stream_cb 打开流#\(id)")
    // 流 ID（恒为正小整数）→ 指针位模式；反解码见 streamID(fromCookie:)
    info.pointee.cookie = UnsafeMutableRawPointer(bitPattern: Int(id))
    info.pointee.read_fn = streamCBRead
    info.pointee.seek_fn = streamCBSeek
    info.pointee.close_fn = streamCBClose
    info.pointee.size_fn = streamCBSize
    return 0
}

extension StreamBridge {
    /// 在 mpv_initialize 之前注册 fm:// 只读协议；成功后 mpv 读请求直接进入 Swift，
    /// 不再经过本地 TCP/HTTP
    static func attachStreamCB(to ctx: OpaquePointer) -> Bool {
        let result = mpv_stream_cb_add_ro(ctx, "fm",
                                          Unmanaged.passUnretained(StreamBridge.shared).toOpaque(),
                                          streamCBOpen)
        AppDebugLog.write("[Bridge] stream_cb 协议注册: code=\(result)")
        return result >= 0
    }
}
#endif
