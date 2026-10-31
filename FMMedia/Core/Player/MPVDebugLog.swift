import Foundation

/// MPV 播放调试日志：统一转发到全局 AppDebugLog（受设置「调试日志」开关控制）
enum MPVDebugLog {
    static func start() {
        AppDebugLog.write("=== MPV 播放会话开始 ===")
    }

    static func stop() {
        AppDebugLog.write("=== MPV 播放会话结束 ===")
    }

    static func write(_ message: String) {
        AppDebugLog.write("[MPV] \(message)")
    }

    static func cleanupOldLogs() {}

    static var latestLogPath: String? { nil }

    static func readLatest() -> String { AppDebugLog.read() }
}
