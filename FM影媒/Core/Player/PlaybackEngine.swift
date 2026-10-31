import Foundation
import UIKit

/// 播放内核抽象：MPV（主）与 VLC（回退）共用
@MainActor
protocol PlaybackEngine: AnyObject {
    var name: String { get }
    /// 是否为主内核（失败时上层会尝试回退到 VLC）
    var isNative: Bool { get }

    var onTime: ((Double) -> Void)? { get set }
    var onDuration: ((Double) -> Void)? { get set }
    var onPlaybackState: ((_ playing: Bool, _ buffering: Bool) -> Void)? { get set }
    var onTracks: (() -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    /// 当前网络下载速度（字节/秒），本地文件为 0
    var onSpeed: ((Double) -> Void)? { get set }
    /// 硬解失败时请求上层切换软件解码
    var onRequireSoftwareRetry: (() -> Void)? { get set }

    func load(_ descriptor: StreamDescriptor, startAt: Double, rate: Double)
    func play()
    func pause()
    func setRate(_ rate: Double)
    func seek(to seconds: Double)
    func makeView() -> UIView
    func teardown()

    func setAspect(_ aspect: PlayerAspect)
    func audioTracks() -> [PlaybackAudioTrack]
    func selectAudioTrack(_ id: String?)
    func videoTracks() -> [PlaybackVideoTrack]
    func selectVideoTrack(_ id: String?)

    func embeddedTracks() -> [PlaybackSubtitleTrack]
    func selectEmbeddedTrack(_ id: String?)
}

extension PlaybackEngine {
    func setAspect(_ aspect: PlayerAspect) {}
    func audioTracks() -> [PlaybackAudioTrack] { [] }
    func selectAudioTrack(_ id: String?) {}
    func videoTracks() -> [PlaybackVideoTrack] { [] }
    func selectVideoTrack(_ id: String?) {}
    func embeddedTracks() -> [PlaybackSubtitleTrack] { [] }
    func selectEmbeddedTrack(_ id: String?) {}
}

struct PlaybackSubtitleTrack: Identifiable, Hashable {
    let id: String
    let name: String
}

struct PlaybackAudioTrack: Identifiable, Hashable {
    let id: String
    let name: String
}

struct PlaybackVideoTrack: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 画面比例
enum PlayerAspect: String, Codable, CaseIterable, Identifiable, Hashable {
    case auto
    case fill
    case stretch
    case ratio16x9
    case ratio4x3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自适应"
        case .fill: return "填充画面"
        case .stretch: return "拉伸铺满"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        }
    }
}

/// 视频解码方式（MPV / VLC 均支持软硬解切换）
enum PlaybackDecodeMode: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case auto
    case hardware
    case software

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .hardware: return "硬件解码"
        case .software: return "软件解码"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "优先 VideoToolbox 硬解，失败自动回退软解"
        case .hardware: return "只用硬解，省电；个别编码可能失败"
        case .software: return "只用 CPU 软解，兼容性最好、更耗电"
        }
    }

    /// libvlc 的 avcodec-hw 取值
    var vlcValue: String {
        switch self {
        case .auto: return "any"
        case .hardware: return "videotoolbox"
        case .software: return "none"
        }
    }

    /// libmpv 的 hwdec 取值
    var mpvValue: String {
        switch self {
        case .auto: return "auto-safe"
        case .hardware: return "videotoolbox"
        case .software: return "no"
        }
    }
}

enum PlaybackEngineKind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case auto
    case mpv

    var id: String { rawValue }

    /// 兼容旧版本设置里的 "system"（AVPlayer 已移除）
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaybackEngineKind(rawValue: raw) ?? .auto
    }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .mpv: return "MPV 全格式"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "MPV 优先，失败自动回退 VLC"
        case .mpv: return "FFmpeg + libmpv，格式覆盖最广"
        }
    }
}

@MainActor
enum PlaybackEngineFactory {
    static var isMPVAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    static func make(kind: PlaybackEngineKind, pathExtension: String, decode: PlaybackDecodeMode = .auto) -> PlaybackEngine {
        // MPV 是唯一内核（AVPlayer / VLC 已移除）
        return makeMPV(decode: decode) ?? MPVPlayerEngine(decode: decode)
    }

    static func makeMPV(decode: PlaybackDecodeMode = .auto) -> PlaybackEngine? {
        #if canImport(Libmpv)
        return MPVPlayerEngine(decode: decode)
        #else
        return nil
        #endif
    }

}
