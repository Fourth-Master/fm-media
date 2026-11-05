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

// MARK: - 单个桥接流（分段多连接取流）

/// 每个远端流一个实例：维护分段缓存窗口，自适应并发从上游拉取
actor BridgeStream {
    static let segmentSize: Int64 = 4 * 1024 * 1024
    /// 浏览器 UA：部分服务器/WAF 拦截客户端 UA
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"

    let meter = BridgeSpeedMeter()
    let url: URL
    let headers: [String: String]

    private var totalBytes: Int64?
    private var segments: [Int: Data] = [:]
    private var inflight: Set<Int> = []
    private var failedSegments: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var servedSegment = 0
    private var workers = 4
    private var cancelled = false
    private var lastAdjustAt: Double = 0
    private var lastSpeedLogAt: Double = 0

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
        // 新一轮请求：清空失败标记，给上游重新连接的机会
        failedSegments.removeAll(keepingCapacity: false)
        servedSegment = Int(rawStart / Self.segmentSize)
        scheduleFills()

        let head = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(end - rawStart + 1)\r\n"
            + "Content-Range: bytes \(rawStart)-\(end)/\(total)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Connection: close\r\n\r\n"
        guard await Self.sendRaw(connection, data: Data(head.utf8)) else { return }

        var offset = rawStart
        while offset <= end, !cancelled, !Task.isCancelled {
            guard let chunk = await readSlice(at: offset, maxLength: 256 * 1024), !chunk.isEmpty else {
                AppDebugLog.write("[Bridge] 上游中断 @ \(offset)，等待 mpv 重发 Range")
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

    // MARK: 分段调度

    private func scheduleFills() {
        guard !cancelled, let total = totalBytes else { return }
        // 正在读取的段最高优先级：绕过并发上限，保证 mpv 当前位置永不饿死（如 seek 后旧段仍在路上）
        let current = servedSegment
        if segments[current] == nil, !inflight.contains(current), !failedSegments.contains(current) {
            inflight.insert(current)
            Task { await self.fetchSegment(current) }
        }
        let lastSegment = Int((total - 1) / Self.segmentSize)
        let windowEnd = min(servedSegment + workers + 4, lastSegment)
        guard servedSegment <= windowEnd else { return }
        var idx = servedSegment
        while inflight.count < workers, idx <= windowEnd {
            if segments[idx] == nil, !inflight.contains(idx), !failedSegments.contains(idx) {
                inflight.insert(idx)
                Task { await self.fetchSegment(idx) }
            }
            idx += 1
        }
    }

    private func fetchSegment(_ idx: Int) async {
        defer {
            inflight.remove(idx)
            scheduleFills()
        }
        guard let total = totalBytes, !cancelled else { return }
        let start = Int64(idx) * Self.segmentSize
        let end = min(start + Self.segmentSize, total) - 1
        guard start <= end else { return }
        for attempt in 1...3 {
            if cancelled { return }
            do {
                let data = try await fetchRange(start, end)
                meter.record(data.count)
                adjustWorkersIfNeeded()
                logSpeedIfNeeded()
                segments[idx] = data
                wake(idx)
                return
            } catch {
                AppDebugLog.write("[Bridge] 段#\(idx) 第\(attempt)次失败: \(error.localizedDescription)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000) }
            }
        }
        // 三次重试仍失败：标记该段失败并唤醒等待者（连接断开，mpv 会重发 Range 开新一轮）
        failedSegments.insert(idx)
        wake(idx)
    }

    private func fetchRange(_ start: Int64, _ end: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        applyHeaders(to: &request)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let expected = Int(end - start + 1)
        if http.statusCode == 200 {
            // 服务器忽略 Range：仅第 0 段可整包切片，其余视为失败走重试
            guard start == 0, !data.isEmpty else { throw URLError(.unsupportedURL) }
            guard data.count >= expected else { throw URLError(.networkConnectionLost) }
            return data.subdata(in: 0..<expected)
        }
        if data.count > expected { return data.subdata(in: 0..<expected) }
        if data.count < expected { throw URLError(.networkConnectionLost) }
        return data
    }

    private func readSlice(at offset: Int64, maxLength: Int) async -> Data? {
        guard !cancelled else { return nil }
        let seg = Int(offset / Self.segmentSize)
        let segOffset = Int(offset % Self.segmentSize)
        if seg != servedSegment {
            servedSegment = seg
            discardOutOfWindow()
            scheduleFills()
        }
        while !cancelled, segments[seg] == nil, !failedSegments.contains(seg) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[seg, default: []].append(continuation)
            }
        }
        guard !cancelled, let data = segments[seg] else { return nil }
        let upper = min(segOffset + maxLength, data.count)
        guard segOffset < upper else { return nil }
        return data.subdata(in: segOffset..<upper)
    }

    private func discardOutOfWindow() {
        let keepBehind = servedSegment
        let keepAhead = servedSegment + workers + 12
        for idx in segments.keys where idx < keepBehind || idx > keepAhead {
            segments.removeValue(forKey: idx)
        }
    }

    private func wake(_ seg: Int) {
        guard let list = waiters.removeValue(forKey: seg) else { return }
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
