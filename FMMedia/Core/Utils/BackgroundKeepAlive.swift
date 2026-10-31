import AVFoundation
import UIKit

/// 扫描期间保持 App 在后台 / 锁屏状态下继续运行。
/// 原理：后台音频模式（UIBackgroundModes=audio）+ 循环播放运行时生成的静音 WAV，
/// 配合 beginBackgroundTask 作为音频会话建立前的兜底。
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var activeCount = 0

    func begin() {
        activeCount += 1
        guard activeCount == 1 else { return }
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "FMMediaScan") { [weak self] in
                self?.expireBackgroundTask()
            }
        }
        startSilentAudio()
        Log.info("扫描保活已开启")
    }

    func end() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        stopSilentAudio()
        expireBackgroundTask()
        Log.info("扫描保活已关闭")
    }

    private func expireBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func startSilentAudio() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: BackgroundKeepAlive.silentWAV(seconds: 2))
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            Log.error("扫描保活音频启动失败: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 运行时生成 2 秒 8kHz 16bit 单声道静音 WAV
    private static func silentWAV(seconds: Int) -> Data {
        let sampleRate = 8000
        let dataSize = sampleRate * seconds * 2
        var data = Data()

        func append(_ string: String) { data.append(string.data(using: .ascii) ?? Data()) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)                      // fmt 块长度
        append16(1)                       // PCM
        append16(1)                       // 单声道
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))  // 字节率
        append16(2)                       // 块对齐
        append16(16)                      // 位深
        append("data")
        append32(UInt32(dataSize))
        data.append(contentsOf: repeatElement(0, count: dataSize))
        return data
    }
}
