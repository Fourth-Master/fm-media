import Foundation

/// MPV 播放调试日志：写入本地文件，方便远程排查
enum MPVDebugLog {
    nonisolated(unsafe) static var logFilePath: String = ""
    private static let lock = NSLock()

    static func start() {
        lock.lock()
        defer { lock.unlock() }
        let dir = FileStore.caches.appendingPathComponent("MPVLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = dir.appendingPathComponent("mpv-\(formatter.string(from: Date())).log").path
        // 确保文件存在（FileHandle(forWritingAtPath:) 在文件不存在时返回 nil）
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        logFilePath = path
        writeLocked("=== MPV 调试日志 ===")
    }

    static func stop() {
        lock.lock()
        writeLocked("=== stop ===")
        logFilePath = ""
        lock.unlock()
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(message)
    }

    private static func writeLocked(_ message: String) {
        guard !logFilePath.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFilePath) {
                if let handle = FileHandle(forWritingAtPath: logFilePath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFilePath, contents: data)
            }
        }
    }

    /// 清理超过 3 天的旧日志
    static func cleanupOldLogs() {
        let dir = FileStore.caches.appendingPathComponent("MPVLogs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static var latestLogPath: String? {
        logFilePath.isEmpty ? nil : logFilePath
    }

    /// 读取最近的日志内容
    static func readLatest() -> String {
        guard !logFilePath.isEmpty, let data = FileManager.default.contents(atPath: logFilePath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
