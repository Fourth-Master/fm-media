import Foundation
import Network

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

// MARK: - 单个桥接流（分段流式多连接取流）

/// 每个远端流一个实例：
/// - 段缓存 1MB/段，fetcher 用 URLSession.bytes 边下边写，pump 边读边发（不攒整段）
/// - 每个连接（mpv 打开的每个 Range 请求）一个独立预取窗口，互不干扰
/// - 自适应并发 4→12：聚合速度低时自动加连接
actor BridgeStream {
    static let segmentSize: Int64 = 1024 * 1024
    /// 浏览器 UA：部分服务器/WAF 拦截客户端 UA
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"

    let meter = BridgeSpeedMeter()
    let url: URL
    let headers: [String: String]

    /// 段：流式缓冲，可能未完成（done=false 时 buffer 也可部分读取）
    private final class Segment {
        var buffer = Data()
        var done = false
        var errorMessage: String?
    }

    /// 每个连接的读取窗口（独立 servedSegment，避免多连接互踩）
    private final class Reader {
        var servedSegment: Int
        init(servedSegment: Int) { self.servedSegment = servedSegment }
    }

    private var totalBytes: Int64?
    private var segments: [Int: Segment] = [:]
    private var inflight: Set<Int> = []
    private var inflightTasks: [Int: Task<Void, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var readers: [Reader] = []
    private var workers = 4
    private var cancelled = false
    private var lastAdjustAt = Date().timeIntervalSinceReferenceDate
    private var lastSpeedLogAt = Date().timeIntervalSinceReferenceDate

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30     // 数据间空闲超时
        config.timeoutIntervalForResource = 300   // 单段总时长上限
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init(url: URL, headers: [String: String], totalBytes: Int64?) {
        self.url = url
        self.headers = headers
        self.totalBytes = totalBytes
    }

    func cancel() {
        cancelled = true
        for task in inflightTasks.values { task.cancel() }
        inflightTasks.removeAll()
        wakeAll()
    }

    // MARK: 请求服务

    /// 服务一个 mpv 请求：回 206 头后从 rawStart 顺序泵数据到 rawEnd
    func serve(connection: NWConnection, rawStart: Int64, rawEnd: Int64?) async {
        guard !cancelled, let total = await ensureTotal() else {
            Self.sendSimple(connection, status: "502 Bad Gateway")
            return
        }
        var end = rawEnd ?? (total - 1)
        if end >= total { end = total - 1 }
        guard rawStart >= 0, rawStart <= end else {
            Self.sendSimple(connection, status: "416 Range Not Satisfiable")
            return
        }
        AppDebugLog.write("[Bridge] 连接 offset=\(rawStart)-\(end)")
        // 清理上次连接留下的失败段（mpv 重连时重新拉取）
        segments = segments.filter { $0.value.errorMessage == nil }
        let reader = Reader(servedSegment: Int(rawStart / Self.segmentSize))
        readers.append(reader)
        defer {
            readers.removeAll { $0 === reader }
            evictIfNeeded()
        }
        scheduleFills()

        let head = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(end - rawStart + 1)\r\n"
            + "Content-Range: bytes \(rawStart)-\(end)/\(total)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Connection: close\r\n\r\n"
        guard await Self.sendRaw(connection, data: Data(head.utf8)) else {
            connection.cancel()
            return
        }

        var offset = rawStart
        while offset <= end, !cancelled, !Task.isCancelled {
            guard let chunk = await readSlice(reader, at: offset, maxLength: 256 * 1024), !chunk.isEmpty else {
                if !cancelled {
                    AppDebugLog.write("[Bridge] 上游结束 @ \(offset)（EOF/失败），等待 mpv 重发 Range")
                }
                break
            }
            guard await Self.sendRaw(connection, data: chunk) else { break }
            offset += Int64(chunk.count)
        }
        connection.cancel()
    }

    // MARK: 总长探测

    private func ensureTotal() async -> Int64? {
        if let totalBytes { return totalBytes }
        for attempt in 1...3 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                applyHeaders(to: &request)
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let (_, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode == 206,
                   let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = Self.parseContentRangeTotal(range) {
                    totalBytes = total
                    AppDebugLog.write("[Bridge] 探测完成 total=\(total)")
                    return total
                }
                AppDebugLog.write("[Bridge] 探测失败: 服务器不支持 Range (status=\(http.statusCode))")
                return nil
            } catch {
                AppDebugLog.write("[Bridge] 探测失败(\(attempt)/3): \(error.localizedDescription)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
        return nil
    }

    // MARK: 分段调度（每 reader 独立窗口）

    private func scheduleFills() {
        guard !cancelled, totalBytes != nil else { return }
        let lastSegment = Int((totalBytes! - 1) / Self.segmentSize)
        for reader in readers {
            let cur = reader.servedSegment
            ensureFetch(cur)   // 当前读取段最高优先级（绕过并发上限，保证永不饿死）
            let windowEnd = min(cur + workers + 4, lastSegment)
            var idx = cur + 1
            while inflight.count < workers, idx <= windowEnd {
                ensureFetch(idx)
                idx += 1
            }
        }
    }

    private func ensureFetch(_ idx: Int) {
        guard !inflight.contains(idx) else { return }
        let seg: Segment
        if let existing = segments[idx] {
            if existing.done { return }
            seg = existing
        } else {
            seg = Segment()
            segments[idx] = seg
        }
        inflight.insert(idx)
        let task = Task { await self.fetchSegment(idx, seg) }
        inflightTasks[idx] = task
    }

    /// 流式拉取一段：边下边写 buffer 并按 256KB 粒度唤醒等待的 pump
    private func fetchSegment(_ idx: Int, _ seg: Segment) async {
        defer {
            inflight.remove(idx)
            inflightTasks.removeValue(forKey: idx)
            scheduleFills()
        }
        guard let total = totalBytes, !cancelled else { return }
        let start = Int64(idx) * Self.segmentSize
        let end = min(start + Self.segmentSize, total) - 1
        guard start <= end else {
            seg.done = true
            wake(idx)
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            applyHeaders(to: &request)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let (bytes, response) = try await Self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            var recorded = 0
            var lastWake = 0
            for try await byte in bytes {
                if cancelled || Task.isCancelled { return }
                seg.buffer.append(byte)
                if seg.buffer.count - lastWake >= 256 * 1024 {
                    meter.record(seg.buffer.count - recorded)
                    recorded = seg.buffer.count
                    lastWake = seg.buffer.count
                    wake(idx)
                    adjustWorkersIfNeeded()
                    logSpeedIfNeeded()
                }
            }
            meter.record(seg.buffer.count - recorded)
            seg.done = true
            wake(idx)
        } catch {
            if cancelled || Task.isCancelled { return }
            AppDebugLog.write("[Bridge] 段#\(idx) 失败: \(error.localizedDescription)")
            seg.errorMessage = error.localizedDescription
            seg.done = true
            wake(idx)
        }
    }

    /// 读取指定偏移的数据；段未就绪时等待其流入（上游空闲超时/完成/失败都会唤醒）
    private func readSlice(_ reader: Reader, at offset: Int64, maxLength: Int) async -> Data? {
        guard !cancelled else { return nil }
        let segIdx = Int(offset / Self.segmentSize)
        let segOffset = Int(offset % Self.segmentSize)
        if segIdx != reader.servedSegment {
            reader.servedSegment = segIdx
            scheduleFills()
            evictIfNeeded()
        }
        while !cancelled {
            guard let seg = segments[segIdx] else {
                ensureFetch(segIdx)   // 兜底：理论上 scheduleFills 已覆盖
                await waitForSegment(segIdx)
                continue
            }
            if seg.errorMessage != nil, segOffset >= seg.buffer.count { return nil }  // 上游失败且无更多已到数据
            if segOffset < seg.buffer.count { break }                           // 有数据可读
            if seg.done { return nil }                                          // 段正常读完（EOF）
            await waitForSegment(segIdx)
        }
        guard !cancelled, let seg = segments[segIdx] else { return nil }
        let upper = min(segOffset + maxLength, seg.buffer.count)
        guard segOffset < upper else { return nil }
        return seg.buffer.subdata(in: segOffset..<upper)
    }

    private func waitForSegment(_ idx: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[idx, default: []].append(continuation)
        }
    }

    /// 淘汰缓存：保留任一 reader 窗口内的段，超出总量上限时淘汰窗口外的段
    private func evictIfNeeded() {
        guard !readers.isEmpty else {
            segments.removeAll()
            return
        }
        var retained = Set<Int>()
        for reader in readers {
            for i in reader.servedSegment...(reader.servedSegment + workers + 4) {
                retained.insert(i)
            }
        }
        let cap = max(24, readers.count * (workers + 4) + 8)
        guard segments.count > cap else { return }
        let removable = segments.keys.filter { !retained.contains($0) }.sorted()
        var excess = segments.count - cap
        for idx in removable where excess > 0 {
            guard !inflight.contains(idx) else { continue }
            segments.removeValue(forKey: idx)
            excess -= 1
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

    // MARK: 自适应并发与日志

    private func adjustWorkersIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastAdjustAt >= 5 else { return }
        lastAdjustAt = now
        let speed = meter.speed()
        if speed < 1_500_000, workers < 12 {
            workers += 2
            AppDebugLog.write("[Bridge] 速度 \(Self.mb(speed))MB/s 偏低，并发 → \(workers)")
            scheduleFills()
        } else if speed > 3_000_000, workers > 4 {
            workers = max(4, workers - 2)
            AppDebugLog.write("[Bridge] 速度 \(Self.mb(speed))MB/s 充足，并发 → \(workers)")
        }
    }

    private func logSpeedIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSpeedLogAt >= 5 else { return }
        lastSpeedLogAt = now
        AppDebugLog.write("[Bridge] 速度 \(Self.mb(meter.speed()))MB/s（\(workers) 连接，缓存 \(segments.count) 段）")
    }

    // MARK: 工具

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    nonisolated private static func mb(_ bytesPerSec: Double) -> String {
        String(format: "%.2f", bytesPerSec / 1_000_000)
    }

    nonisolated static func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(tail)
    }

    nonisolated static func sendRaw(_ connection: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    nonisolated static func sendSimple(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - 本地桥接服务器

/// mpv 从 127.0.0.1 取流，桥内用 URLSession 多连接分段从远端取数据。
/// 单例懒启动；注册表中的流随引擎 teardown 注销。
/// register/localURL/unregister 仅主线程调用（播放引擎侧保证），speed 允许后台线程读。
final class StreamBridge {
    static let shared = StreamBridge()

    private var listener: NWListener?
    private var port: UInt16?
    private var nextID: Int64 = 1

    private let streamsLock = NSLock()
    private var streams: [Int64: BridgeStream] = [:]

    private let queue = DispatchQueue(label: "fmmedia.streambridge", qos: .userInitiated)

    private init() {}

    // MARK: 注册表

    /// 注册远端流；服务器启动失败返回 nil（调用方回退 mpv 直连）
    func register(url: URL, headers: [String: String], totalBytes: Int64?) -> Int64? {
        guard ensureStarted() else { return nil }
        let id = nextID
        nextID += 1
        streamsLock.lock()
        streams[id] = BridgeStream(url: url, headers: headers, totalBytes: totalBytes)
        streamsLock.unlock()
        let headerNames = headers.keys.joined(separator: ",")
        AppDebugLog.write("[Bridge] 注册流#\(id): \(url.absoluteString.prefix(100)) headers=[\(headerNames)] total=\(totalBytes.map(String.init) ?? "?")")
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
        if let stream {
            AppDebugLog.write("[Bridge] 注销流#\(id)")
            Task { await stream.cancel() }
        }
    }

    /// 桥的聚合取流速度（字节/秒），供网速显示
    func speed(for id: Int64) -> Double {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return streams[id]?.meter.speed() ?? 0
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
            BridgeStream.sendSimple(box.connection, status: "400 Bad Request")
            return
        }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else {
            BridgeStream.sendSimple(box.connection, status: "400 Bad Request")
            return
        }
        let path = String(parts[1])
        guard path.hasPrefix("/s/"), let id = Int64(path.dropFirst(3)) else {
            BridgeStream.sendSimple(box.connection, status: "404 Not Found")
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
            BridgeStream.sendSimple(box.connection, status: "404 Not Found")
            return
        }
        box.task = Task { await stream.serve(connection: box.connection, rawStart: start, rawEnd: end) }
    }
}
