import Foundation
import UIKit

/// 全局调试日志：写入 Documents 目录，可在系统「文件」App 中查看
enum AppDebugLog {
    nonisolated(unsafe) static var enabled = false
    private static let lock = NSLock()
    private static var filePath: String = ""

    static var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    static var logFileURL: URL {
        URL(fileURLWithPath: documentsPath).appendingPathComponent("debug.log")
    }

    static func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        filePath = on ? logFileURL.path : ""
        lock.unlock()
        // 注意：必须在锁外调用 write（write 会再次加锁，锁内调用会死锁）
        if on {
            write("=== 调试日志开启 === App v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
            trimIfNeeded()
        }
    }

    static func write(_ message: String) {
        guard enabled, !filePath.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: filePath)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: url.path, contents: data)
            }
        }
    }

    static func read() -> String {
        let url = logFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: logFileURL)
        filePath = enabled ? logFileURL.path : ""
        lock.unlock()
    }

    /// 超过 2MB 时保留末尾 1MB，避免无限增长
    static func trimIfNeeded() {
        let url = logFileURL
        guard fileSize > 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(1024 * 1024)
        var kept = Data(tail)
        if let newline = tail.firstIndex(of: 0x0A) {
            kept = Data(tail[tail.index(after: newline)...])
        }
        FileManager.default.createFile(atPath: url.path, contents: kept)
    }

    static var fileSize: Int64 {
        let url = logFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
}
