import Foundation
import UIKit

/// 全局调试日志：写入 Documents 目录，可在系统「文件」App 中查看
/// - 文件超过 2MB 自动轮转（debug.log → debug.old.log）
/// - 高频刷屏时自动节流（每秒最多 ~30 条，丢弃的按秒汇总）
/// - 相同消息连续重复时合并为 ×N 计数
enum AppDebugLog {
    nonisolated(unsafe) static var enabled = false
    private static let lock = NSLock()
    private static var filePath: String = ""
    private static var writeCount = 0
    private static var lastMessage = ""
    private static var repeatCount = 0
    private static var currentSecond: Int = -1
    private static var writesThisSecond = 0
    private static var droppedThisSecond = 0
    private static let maxWritesPerSecond = 30
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    static var logFileURL: URL {
        URL(fileURLWithPath: documentsPath).appendingPathComponent("debug.log")
    }

    static var oldLogFileURL: URL {
        URL(fileURLWithPath: documentsPath).appendingPathComponent("debug.old.log")
    }

    static func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        filePath = on ? logFileURL.path : ""
        writeCount = 0
        lock.unlock()
        // 版本更新后自动清除旧版本日志（对排查新版无意义）；
        // 关闭时也执行检查——App 启动应用设置即会清理旧版本遗留文件
        clearIfVersionChanged()
        if on {
            write("=== 调试日志开启 === App v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        }
    }

    /// 记录日志归属的版本号；版本变化时清掉新旧日志文件
    private static func clearIfVersionChanged() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let key = "debugLog.version"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        lock.lock()
        try? FileManager.default.removeItem(at: logFileURL)
        try? FileManager.default.removeItem(at: oldLogFileURL)
        lastMessage = ""
        repeatCount = 0
        writeCount = 0
        lock.unlock()
        UserDefaults.standard.set(version, forKey: key)
    }

    static func write(_ message: String) {
        guard enabled, !filePath.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        // 相同消息连续重复：合并为 ×N 计数，只在关键节点落盘
        if message == lastMessage {
            repeatCount += 1
            if repeatCount == 2 || repeatCount == 5 || repeatCount == 10
                || (repeatCount > 10 && repeatCount % 50 == 0) {
                append("[×\(repeatCount)] \(message)")
            }
            return
        }
        if repeatCount > 1 {
            append("[同上 ×\(repeatCount)]")
        }
        lastMessage = message
        repeatCount = 0

        // 每秒限流：超过上限的丢弃并按秒汇总，防止刷屏拖垮磁盘与内存
        let second = Int(Date().timeIntervalSince1970)
        if second != currentSecond {
            if droppedThisSecond > 0 {
                append("[节流] 上一秒丢弃 \(droppedThisSecond) 条日志")
            }
            currentSecond = second
            writesThisSecond = 0
            droppedThisSecond = 0
        }
        if writesThisSecond >= maxWritesPerSecond {
            droppedThisSecond += 1
            return
        }
        writesThisSecond += 1
        append(message)
    }

    /// 追加一行（锁内调用）；超过 2MB 时轮转
    private static func append(_ message: String) {
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
        writeCount += 1
        if writeCount % 256 == 0, fileSize > 2 * 1024 * 1024 {
            rotate()
        }
    }

    /// 轮转：当前日志改名保留一份旧日志，重新开始
    private static func rotate() {
        try? FileManager.default.removeItem(at: oldLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: oldLogFileURL)
    }

    /// 读取完整日志（复制/导出用）
    static func read() -> String {
        Self.readContent(from: logFileURL)
    }

    /// 读取末尾片段（界面显示用，避免大文件卡死）
    static func readTail(maxBytes: Int = 512 * 1024) -> String {
        let url = logFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else { return "" }
        if size <= Int64(maxBytes) {
            return read()
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(size - Int64(maxBytes)))
        let tail = handle.readDataToEndOfFile()
        var text = String(data: tail, encoding: .utf8) ?? ""
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return "（日志较大，仅显示末尾 \(maxBytes / 1024)KB，完整内容请用「复制」）\n" + text
    }

    private static func readContent(from url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: logFileURL)
        try? FileManager.default.removeItem(at: oldLogFileURL)
        filePath = enabled ? logFileURL.path : ""
        writeCount = 0
        lastMessage = ""
        repeatCount = 0
        lock.unlock()
    }

    static var fileSize: Int64 {
        let url = logFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
}
