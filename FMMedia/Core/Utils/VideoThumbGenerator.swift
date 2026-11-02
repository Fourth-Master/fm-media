import AVFoundation
import UIKit

/// 为未识别且无封面的本机视频生成截帧封面，缓存于 App Support/VideoThumbs
enum VideoThumbGenerator {
    static var thumbDirectory: URL {
        let dir = FileStore.appData.appendingPathComponent("VideoThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cachedURL(for videoPath: String) -> URL {
        let sanitized = videoPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = sanitized.count > 120 ? String(sanitized.suffix(120)) : sanitized
        return thumbDirectory.appendingPathComponent(name + ".jpg")
    }

    /// 生成或复用截帧封面（取视频约 10% 处的关键帧）；失败返回 nil
    static func generate(forVideoPath videoPath: String) -> URL? {
        let target = cachedURL(for: videoPath)
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.5 else { return nil }
        let seconds = min(max(duration * 0.1, 1.0), duration - 0.2)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 8, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 8, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil) else { return nil }

        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        do {
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }
}
