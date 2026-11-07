import Foundation

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

// MARK: - 流文件下载器（稀疏文件全量填充）

/// 每个远端流一个实例（同一 URL 重建引擎时复用，已下载段保留）：
/// - 稀疏临时文件 truncate 到文件总长，8MB 段整段拉取（实测 17-20MB/s），
///   严格校验 206+长度后写入磁盘对应偏移
/// - prepare：先下文件头 + moov（尾部）+ 起播位置窗口，就绪后 mpv loadfile 本地路径
/// - mpv 直读本地文件：所有 seek 都是磁盘操作，与网络完全解耦
/// - 后台顺序填充全文件：填满后任意 seek 瞬时；未填满区域若被 demuxer 读到，
///   因音视频交错距离极端（实测 1GB+）无法完全避免，靠全量填充尽快覆盖
actor StreamFileFetcher {
    static let segmentSize: Int64 = 8 * 1024 * 1024
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
    private var fileHandle: FileHandle?
    private var cancelled = false
    private var lastSpeedLogAt = Date().timeIntervalSinceReferenceDate
    private var prepared = false

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
        // forUpdating = O_RDWR：读服务要从这个句柄读数据（forWritingTo 是只写，读会崩）
        self.fileHandle = try? FileHandle(forUpdating: fileURL)
    }

    nonisolated func matches(url: URL, total: Int64) -> Bool {
        self.url == url && totalBytes == total
    }

    func cancel() {
        cancelled = true
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var segmentCount: Int {
        Int((totalBytes - 1) / Self.segmentSize) + 1
    }

    private func segment(at idx: Int) -> Segment {
        if let seg = segments[idx] { return seg }
        let seg = Segment()
        segments[idx] = seg
        return seg
    }

    var downloadedSegments: Int {
        segments.values.filter { $0.done }.count
    }

    // MARK: 关键区预下载（prepare）

    /// 下载 mpv 打开所需的全部区域：文件头 + moov（尾部）+ 起播位置窗口。
    /// 完成（返回 true）后 mpv 才能 loadfile 本地文件；后台继续填满全文件。
    func prepare(startAtSeconds: Double) async -> Bool {
        guard fileHandle != nil else { return false }
        let segCount = segmentCount
        // 1. moov 在尾部：先下最后 2 段
        let tailStart = max(0, segCount - 2)
        await fetchBatch(tailStart..<segCount, tag: "moov")
        // 2. 文件头（ftyp）
        await fetchBatch(0..<1, tag: "header")
        // 3. 从 moov 解析总时长 → 换算起播字节偏移（VBR 下为估算，窗口冗余覆盖）
        let totalSeconds = await parseDuration() ?? 0
        var startByte: Int64 = 0
        if totalSeconds > 0, startAtSeconds > 0 {
            startByte = min(Int64(startAtSeconds / totalSeconds * Double(totalBytes)), totalBytes - 1)
        }
        AppDebugLog.write("[Bridge] moov 时长 \(String(format: "%.0f", totalSeconds))s → 起播偏移 \(startByte)（请求 \(String(format: "%.0f", startAtSeconds))s）")
        // 4. 起播窗口：起播段 + 后 4 段 + 前 2 段（关键帧可能略早于目标偏移）
        let startSeg = Int(startByte / Self.segmentSize)
        var window = Set<Int>()
        for i in max(0, startSeg - 2)..<min(startSeg + 5, segCount) { window.insert(i) }
        window.insert(0)
        await fetchBatch(window, tag: "起播窗口")
        prepared = true
        startFillLoop()
        return true
    }

    /// 并发拉取一批段
    private func fetchBatch(_ idxs: any Sequence<Int>, tag: String) async {
        let list = idxs.filter { segments[$0]?.done != true }
        guard !list.isEmpty else { return }
        AppDebugLog.write("[Bridge] 预下载[\(tag)]: \(list.count) 段")
        await withTaskGroup(of: Void.self) { group in
            for idx in list {
                let seg = segment(at: idx)
                group.addTask { await self.fetchSegment(idx, seg) }
            }
        }
    }

    // MARK: 后台顺序填充

    private func startFillLoop() {
        Task { await fillAll() }
    }

    /// 从 0 到 EOF 顺序填充所有未完成段（已完成的跳过）
    private func fillAll() async {
        let segCount = segmentCount
        var consecutiveFailures = 0
        while !cancelled {
            guard let base = (0..<segCount).first(where: { segments[$0]?.done != true }) else {
                AppDebugLog.write("[Bridge] 全文件下载完成（\(segCount) 段）")
                return
            }
            let batch = (base..<min(base + 4, segCount)).filter { segments[$0]?.done != true }
            await withTaskGroup(of: Void.self) { group in
                for idx in batch {
                    let seg = segment(at: idx)
                    group.addTask { await self.fetchSegment(idx, seg) }
                }
            }
            let failed = batch.filter { segments[$0]?.done != true }.count
            if failed > 0 {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    AppDebugLog.write("[Bridge] 连续 \(consecutiveFailures) 批存在失败段，暂停填充 5 秒")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if consecutiveFailures >= 6 { return }   // 上游彻底不可用，停止填充
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                consecutiveFailures = 0
            }
        }
    }

    private func fetchSegment(_ idx: Int, _ seg: Segment) async {
        guard !cancelled else { return }
        let start = Int64(idx) * Self.segmentSize
        let end = min(start + Self.segmentSize, totalBytes) - 1
        guard start <= end else {
            seg.done = true
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
                logSpeedIfNeeded(speed: meter.speed())
                return
            } catch {
                if cancelled || Task.isCancelled { return }
                AppDebugLog.write("[Bridge] 段#\(idx) 第\(attempt)次失败: \(error.localizedDescription)")
            }
        }
        seg.errorMessage = "attempts exhausted"
    }

    // MARK: moov 时长解析

    /// 从已下载的尾部数据解析 mvhd 的总时长（秒）；失败返回 nil
    private func parseDuration() async -> Double? {
        guard let handle = fileHandle else { return nil }
        let tailSeg = max(0, segmentCount - 2)
        let start = Int64(tailSeg) * Self.segmentSize
        let length = Int(totalBytes - start)
        handle.seek(toFileOffset: UInt64(start))
        let data = handle.readData(ofLength: length)
        guard !data.isEmpty else { return nil }
        guard let marker = data.range(of: Data("mvhd".utf8)) else {
            AppDebugLog.write("[Bridge] moov 中未找到 mvhd")
            return nil
        }
        // mvhd: size(4)+type(4)+version(1)+flags(3)+ctime+mtime+timescale+duration
        let base = marker.upperBound   // version 起始
        guard base + 20 <= data.count else { return nil }
        let version = data[base]
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt64 {
            UInt64(bytes[offset]) << 24 | UInt64(bytes[offset + 1]) << 16 | UInt64(bytes[offset + 2]) << 8 | UInt64(bytes[offset + 3])
        }
        var offset = base + 4                     // 跳过 version+flags
        offset += version == 1 ? 16 : 8           // creation + modification
        let timescale = u32(offset)
        offset += 4
        var duration: UInt64
        if version == 1 {
            guard offset + 8 <= bytes.count else { return nil }
            duration = u32(offset) << 32 | u32(offset + 4)
        } else {
            duration = u32(offset)
        }
        guard timescale > 0, duration > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }

    // MARK: 工具

    private func logSpeedIfNeeded(speed: Double) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSpeedLogAt >= 5 else { return }
        lastSpeedLogAt = now
        AppDebugLog.write("[Bridge] 下载 \(String(format: "%.2f", speed / 1_000_000))MB/s（已下 \(downloadedSegments)/\(segmentCount) 段）")
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

// MARK: - 流文件管理器

/// 管理稀疏临时文件与下载器生命周期。同一 URL 重建引擎时复用已下载数据。
/// register/prepare/unregister 仅主线程调用（播放引擎侧保证），speed 允许后台线程读。
final class StreamBridge {
    static let shared = StreamBridge()

    private let lock = NSLock()
    private var nextID: Int64 = 1
    private var current: (id: Int64, fetcher: StreamFileFetcher)?

    private init() {}

    /// 注册远端流（需要总长以创建稀疏文件）；同一 URL 复用现有下载器（已下载段保留）
    func register(url: URL, headers: [String: String], totalBytes: Int64?) -> Int64? {
        guard let total = totalBytes, total > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = current, existing.fetcher.matches(url: url, total: total) {
            return existing.id   // 同一 URL 重建引擎（seek/重试）：复用已下载数据
        }
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
        current = (id, fetcher)
        AppDebugLog.write("[Bridge] 注册流#\(id): \(url.absoluteString.prefix(100)) total=\(total)（稀疏磁盘文件）")
        return id
    }

    /// 预下载关键区（文件头+moov+起播窗口）；就绪返回本地文件路径供 mpv loadfile
    func prepare(id: Int64, startAtSeconds: Double) async -> URL? {
        lock.lock()
        let fetcher = current?.fetcher
        let matches = current?.id == id
        lock.unlock()
        guard matches, let fetcher else { return nil }
        let ok = await fetcher.prepare(startAtSeconds: startAtSeconds)
        guard ok else { return nil }
        return await fetcher.fileURLValue
    }

    func unregister(_ id: Int64) {
        lock.lock()
        let entry = current
        lock.unlock()
        guard let entry, entry.id == id else { return }
        AppDebugLog.write("[Bridge] 注销流#\(id)（清理临时文件）")
        Task { await entry.fetcher.cancel() }
        lock.lock()
        current = nil
        lock.unlock()
    }

    /// 下载速度（字节/秒），供网速显示
    func speed(for id: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard current?.id == id else { return 0 }
        return current?.fetcher.meter.speed() ?? 0
    }
}

extension StreamFileFetcher {
    var fileURLValue: URL? {
        cancelled ? nil : fileURL
    }
}
