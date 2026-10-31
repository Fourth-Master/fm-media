import Foundation
import Security

struct MediaActor: Codable, Hashable, Identifiable {
    var name: String
    var role: String = ""
    var thumb: ImageRef? = nil

    var id: String { "\(name)-\(role)" }
}

/// 智能媒体库条目
struct MediaItem: Identifiable, Hashable, Codable {
    var id: String
    var code: String
    var rawName: String
    var isCracked: Bool
    var hasSubtitleTag: Bool
    var isRecognized: Bool = true

    var title: String = ""
    /// 数据源中的 originaltitle（NFO / Emby）
    var originalTitle: String? = nil
    var plot: String = ""
    var studio: String = ""
    var publisher: String = ""
    var year: Int? = nil
    var releaseDate: String = ""
    var runtimeMinutes: Int? = nil
    var rating: Double? = nil
    var genres: [String] = []
    var actors: [MediaActor] = []
    var tags: [String] = []

    var poster: ImageRef? = nil
    var fanart: ImageRef? = nil
    var previews: [ImageRef] = []

    var video: MediaFileRef? = nil
    var subtitles: [MediaFileRef] = []
    var nfoPath: String? = nil
    var folderPath: String

    var sourceID: UUID? = nil
    var remoteStream: StreamDescriptor? = nil
    /// 远程来源的同名字幕（播放时按需拉取到本机缓存）
    var remoteSubtitleStreams: [StreamDescriptor] = []
    var durationSeconds: Double? = nil

    var addedAt: Date = Date()
    var modifiedAt: Date? = nil
    var lastPlayed: Date? = nil
    var playProgress: Double = 0

    var displayTitle: String {
        let trimmed = title.trimmed
        return trimmed.isEmpty ? code : trimmed
    }

    var hasSubtitleFiles: Bool { !subtitles.isEmpty || hasSubtitleTag }

    var badges: [String] {
        var result: [String] = []
        if isCracked { result.append("破解") }
        if hasSubtitleFiles { result.append("字幕") }
        if !isRecognized { result.append("未识别") }
        return result
    }

    /// 播放地址
    var stream: StreamDescriptor? {
        if let remoteStream { return remoteStream }
        guard let video else { return nil }
        return StreamDescriptor(url: video.url, title: displayTitle)
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath) }

    var bestArtwork: ImageRef? { fanart ?? poster }
}

/// 媒体来源配置（本机目录 / 媒体服务器 / 云盘 / WebDAV / SMB）
struct MediaSourceConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    var baseURL: String = ""
    var username: String = ""
    var secretKey: String = UUID().uuidString
    var localBookmark: Data? = nil
    var localPath: String? = nil
    var extra: [String: String] = [:]
    var createdAt: Date = Date()
    var lastConnected: Date? = nil
    var isEnabled: Bool = true

    /// 需在 Keychain 中读写
    var secret: String {
        get { SecretStore.get(secretKey) ?? "" }
        set { SecretStore.set(newValue, for: secretKey) }
    }

    var serverPath: String { extra["path"] ?? "" }

    var rootPath: String {
        if kind == .smb { return extra["share"] ?? "" }
        return "/"
    }

    var displayDetail: String {
        switch kind {
        case .local:
            return localPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未授权"
        case .smb:
            let host = URL(string: baseURL)?.host ?? baseURL
            return "\(host)/\(extra["share"] ?? "")"
        default:
            let host = baseURL.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let path = extra["path"], !path.isEmpty {
                return host + path
            }
            return host
        }
    }

    static func local(name: String, url: URL, bookmark: Data?) -> MediaSourceConfig {
        MediaSourceConfig(name: name,
                          kind: .local,
                          localBookmark: bookmark,
                          localPath: url.path)
    }
}

/// Keychain 中保存账号密码 / Token
enum SecretStore {
    private static let service = "com.fmmedia.FMPlayer.secrets"

    static func set(_ value: String, for key: String) {
        guard !key.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
