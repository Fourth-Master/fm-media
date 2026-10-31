import Foundation

/// 字幕外观与同步参数，可在播放过程中实时调整
struct SubtitleStyle: Codable, Equatable, Hashable {
    var fontSize: Double = 20
    var textColorHex: UInt32 = 0xFFFFFF
    var outlineColorHex: UInt32 = 0x000000
    var outlineWidth: Double = 2
    var backgroundOpacity: Double = 0.35
    var bottomInset: Double = 36
    var delayMs: Int = 0
    var bold: Bool = false
    var italic: Bool = false
    var uppercase: Bool = false

    static let `default` = SubtitleStyle()
}

struct SettingsData: Codable, Equatable {
    var subtitleStyle: SubtitleStyle = .default
    var playbackRate: Double = 1.0
    /// 长按临时倍速
    var longPressRate: Double = 2.0
    var autoPlayNext: Bool = false
    var resumePlayback: Bool = true
    var subtitleSearchEnabled: Bool = true
    var xunleiSubtitleEnabled: Bool = true
    var subtitlecatEnabled: Bool = true
    var preferredSubtitleLanguage: String = "zh"
    var librarySort: LibrarySort = .recent
    var libraryFilter: LibraryFilter = .all
    var showUnrecognizedItems: Bool = false
    var showCrackedBadge: Bool = true
    /// 是否启用数据源 genre 作为题材分类
    var enableGenreCategories: Bool = true
    /// 标题是否完整显示（多行不截断）
    var showFullTitle: Bool = false
    /// 媒体库标题显示方式
    var titleDisplay: TitleDisplayMode? = nil
    /// 自定义模式下的小标题字段（可多选）
    var customSubtitleFields: [TitleField]? = nil
    /// 自定义模式下的大标题来源（单选）
    var customTitleField: TitleField? = nil
    var showSubtitleBadge: Bool = true
    var gridColumns: Int = 3
    var maxConcurrentTransfers: Int = 2
    var preferWiFiOnly: Bool = false
    var imageCacheLimitMB: Int = 200
    var autoScanOnLaunch: Bool = true
    var lastLibraryScan: Date? = nil
    /// 播放内核偏好；可选类型以保证旧版本设置文件仍可解码
    var playerEngine: PlaybackEngineKind? = nil
    /// 解码方式偏好（VLC 内核）
    var videoDecode: PlaybackDecodeMode? = nil

    /// 实际生效的内核偏好（默认自动）
    var enginePreference: PlaybackEngineKind {
        get { playerEngine ?? .auto }
        set { playerEngine = newValue }
    }

    /// 实际生效的解码方式（默认自动）
    var decodePreference: PlaybackDecodeMode {
        get { videoDecode ?? .auto }
        set { videoDecode = newValue }
    }

    /// 实际生效的标题显示方式
    var titleMode: TitleDisplayMode {
        get { titleDisplay ?? .originalWithPlot }
        set { titleDisplay = newValue }
    }

    var titleField: TitleField {
        get { customTitleField ?? .originalTitle }
        set { customTitleField = newValue }
    }

    var subtitleFields: [TitleField] {
        get { customSubtitleFields ?? TitleResolver.defaultSubtitleFields }
        set { customSubtitleFields = newValue }
    }
}

/// 用户偏好设置，自动持久化到 UserDefaults 的 JSON
@MainActor
final class AppSettings: ObservableObject {
    @Published var data: SettingsData {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    init() {
        if let saved: SettingsData = JSONStore.load(SettingsData.self, from: "settings.json") {
            data = saved
        } else {
            data = SettingsData()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data
        saveTask = Task { [snapshot] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            JSONStore.save(snapshot, to: "settings.json")
        }
    }
}

/// 极简 JSON 持久化
enum JSONStore {
    static func url(for name: String) -> URL {
        FileStore.appData.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
