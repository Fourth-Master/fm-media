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

// MARK: - 单个桥接流（磁盘-backed 顺序下载器）

/// 每个远端流一个实例：
/// - 后端是稀疏临时文件（truncate 到文件总长），段下载完成后写入对应偏移
/// - mpv 的读请求从磁盘文件服务（已下载段即时返回，未下载段等待下载完成）
/// - 音视频交错距离大（实测 >1GB）的文件会产生海量 demuxer seek，
///   本架构下 seek 只是在磁盘上换位置，与网络完全解耦（猫头鹰同思路）
/// - 下载器按 reader 窗口调度，全局上游并发上限，段失败自动重拉
actor BridgeStream {
    static let segmentSize: Int64 = 8 * 1024 * 1024
    /// 浏览器 UA：部分服务器/WAF 拦截客户端 UA
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"

    let meter = BridgeSpeedMeter()
    let url: URL
    let headers: [String: String]
    let fileURL: URL

    /// 段状态（数据在磁盘文件中，内存只存元信息）
    private final class Segment {
        var done = false
        var errorMessage: String?
    }

    /// 每个连接的读取位置（段号）
    private final class Reader {
        var servedSegment: Int
        init(servedSegment: Int) { self.servedSegment = servedSegment }
    }

    private struct PendingFetch {
        let idx: Int
        let priority: Bool
    }

    private let totalBytes: Int64
    private var segments: [Int: Segment] = [:]
    private var pending: [PendingFetch] = []
    private var inflight: Set<Int> = []
    private var inflightTasks: [Int: Task<Void, Never>] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var readers: [Reader] = []
    private var workers = 2            // 期望预取宽度（慢时自适应 +1，CDN 并发互挤不宜多）
    private let maxUpstream = 4        // 全局上游连接硬上限
    private var upstreamCount = 0
    private var dispatching = false
    private var cancelled = false
    private var fileHandle: FileHandle?
    /// 预取目标：每 reader 领先 8 段（64MB），磁盘 backed 无内存压力
    private var lastAdjustAt = Date().timeIntervalSinceReferenceDate
    private var lastSpeedLogAt = Date().timeIntervalSinceReferenceDate
    private var connectionCount = 0

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30     // 数据间空闲超时
        config.timeoutIntervalForResource = 300   // 单段总时长上限
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
        // forUpdating = O_RDWR：读Slice 要从这个句柄读数据，
        // forWritingTo 是只写句柄，读它会抛 ObjC 异常直接崩溃（1.8.58 闪退根因）
        self.fileHandle = try? FileHandle(forUpdating: fileURL)
    }

    func cancel() {
        cancelled = true
        for task in inflightTasks.values { task.cancel() }
        inflightTasks.removeAll()
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
        scheduleFills()

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

    // MARK: 分段调度（全局并发上限 + 优先级队列）

    private func scheduleFills() {
        guard !cancelled else { return }
        let lastSegment = Int((totalBytes - 1) / Self.segmentSize)
        let windowLen = 8   // 每 reader 预取 8 段 = 64MB（磁盘 backed，无内存压力）
        var wanted = Set<Int>()
        var currentSegments = Set<Int>()
        for reader in readers {
            let cur = reader.servedSegment
            currentSegments.insert(cur)
            wanted.insert(cur)
            var idx = cur + 1
            while idx <= min(cur + windowLen, lastSegment) {
                wanted.insert(idx)
                idx += 1
            }
        }
        // 清掉已不在任何窗口内的排队任务（seek 后旧位置立即让路）
        pending.removeAll { !wanted.contains($0.idx) }
        for idx in wanted {
            ensureFetch(idx, priority: false)
        }
        for idx in currentSegments {
            ensureFetch(idx, priority: true)
        }
        // 当前段未就绪且上游槽满时，取消最远的在途段让路
        let inflightSnapshot = inflight
        let nonCurrent = inflightSnapshot.subtracting(currentSegments)
        if upstreamCount >= maxUpstream, !nonCurrent.isEmpty {
            for cur in currentSegments {
                guard let seg = segments[cur], !seg.done else { continue }
                if inflight.contains(cur) { continue }
                if let victim = nonCurrent.max() {
                    inflightTasks[victim]?.cancel()
                }
            }
        }
        dispatchPending()
    }

    private func ensureFetch(_ idx: Int, priority: Bool) {
        if let seg = segments[idx], seg.done || seg.errorMessage != nil { return }
        if inflight.contains(idx) { return }
        if pending.contains(where: { $0.idx == idx }) { return }
        let item = PendingFetch(idx: idx, priority: priority)
        if priority {
            pending.insert(item, at: 0)
        } else {
            pending.append(item)
        }
    }

    private func dispatchPending() {
        guard !dispatching else { return }
        dispatching = true
        defer { dispatching = false }
        while !cancelled, !pending.isEmpty, upstreamCount < maxUpstream {
            let item = pending.removeFirst()
            guard !inflight.contains(item.idx) else { continue }
            let seg: Segment
            if let existing = segments[item.idx] {
                seg = existing
            } else {
                seg = Segment()
                segments[item.idx] = seg
            }
            if seg.done { continue }
            upstreamCount += 1
            inflight.insert(item.idx)
            let task = Task {
                await self.fetchSegment(item.idx, seg)
            }
            inflightTasks[item.idx] = task
        }
    }

    /// 拉取一段：整段 data(for:)（实测 17-20MB/s），严格校验 206+长度后写入磁盘对应偏移
    private func fetchSegment(_ idx: Int, _ seg: Segment) async {
        defer {
            upstreamCount -= 1
            inflight.remove(idx)
            inflightTasks.removeValue(forKey: idx)
            dispatchPending()
        }
        guard !cancelled, let handle = fileHandle else { return }
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
                handle.seek(toFileOffset: UInt64(start))
                try handle.write(contentsOf: data)
                meter.record(data.count)
                seg.done = true
                wake(idx)
                adjustWorkersIfNeeded()
                logSpeedIfNeeded()
                return
            } catch {
                if cancelled || Task.isCancelled { return }
                AppDebugLog.write("[Bridge] 段#\(idx) 第\(attempt)次失败: \(error.localizedDescription)")
            }
        }
        seg.errorMessage = "attempts exhausted"
        wake(idx)
    }

    /// 读取指定偏移的数据；段未就绪时等待其下载完成
    private func readSlice(_ reader: Reader, at offset: Int64, maxLength: Int) async -> Data? {
        guard !cancelled, let handle = fileHandle else { return nil }
        let segIdx = Int(offset / Self.segmentSize)
        if segIdx != reader.servedSegment {
            reader.servedSegment = segIdx
            scheduleFills()
        }
        var resets = 0
        while !cancelled {
            guard let seg = segments[segIdx] else {
                ensureFetch(segIdx, priority: true)
                dispatchPending()
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
                ensureFetch(segIdx, priority: true)
                dispatchPending()
                await waitForSegment(segIdx)
                continue
            }
            // 孤儿段检测：被抢占取消后无人负责 → 重新入队
            if !inflight.contains(segIdx), !pending.contains(where: { $0.idx == segIdx }) {
                ensureFetch(segIdx, priority: true)
                dispatchPending()
            }
            await waitForSegment(segIdx)
        }
        guard !cancelled, segments[segIdx]?.done == true else { return nil }
        // 读取不得跨越段边界（下一段可能尚未下载）
        let segEnd = min(Int64(segIdx + 1) * Self.segmentSize, totalBytes)
        let readLen = Int(min(Int64(maxLength), segEnd - offset))
        guard readLen > 0 else { return nil }
        handle.seek(toFileOffset: UInt64(offset))
        return handle.readData(ofLength: readLen)
    }

    private func waitForSegment(_ idx: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[idx, default: []].append(continuation)
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
        guard now - lastAdjustAt >= 3 else { return }
        lastAdjustAt = now
        let speed = meter.speed()
        if speed < 1_500_000, workers < maxUpstream {
            workers += 1
            AppDebugLog.write("[Bridge] 速度 \(Self.mb(speed))MB/s 偏低，并发 → \(workers)")
            scheduleFills()
        } else if speed > 5_000_000, workers > 2 {
            workers -= 1
            AppDebugLog.write("[Bridge] 速度 \(Self.mb(speed))MB/s 充足，并发 → \(workers)")
        }
    }

    private func logSpeedIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSpeedLogAt >= 5 else { return }
        lastSpeedLogAt = now
        AppDebugLog.write("[Bridge] 速度 \(Self.mb(meter.speed()))MB/s（\(workers) 连接）")
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
}

// MARK: - 本地桥接服务器

/// mpv 从 127.0.0.1 取流，桥下载到稀疏临时文件并从磁盘服务。
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

    /// 注册远端流（需要总长以创建稀疏文件）；失败返回 nil（调用方回退 mpv 直连）
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
        streamsLock.lock()
        streams[id] = BridgeStream(url: url, headers: headers, totalBytes: total, fileURL: fileURL)
        streamsLock.unlock()
        let headerNames = headers.keys.joined(separator: ",")
        AppDebugLog.write("[Bridge] 注册流#\(id): \(url.absoluteString.prefix(100)) headers=[\(headerNames)] total=\(total)（磁盘-backed）")
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
            AppDebugLog.write("[Bridge] 注销流#\(id)（清理临时文件）")
            Task { await stream.cancel() }
        }
    }

    /// 桥的聚合下载速度（字节/秒），供网速显示
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
