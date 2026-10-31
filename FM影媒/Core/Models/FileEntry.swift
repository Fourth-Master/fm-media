import Foundation

enum FileKind: String, Codable, Hashable {
    case folder
    case video
    case subtitle
    case image
    case nfo
    case audio
    case document
    case archive
    case other

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .subtitle: return "captions.bubble.fill"
        case .image: return "photo.fill"
        case .nfo: return "doc.text.fill"
        case .audio: return "music.note"
        case .document: return "doc.fill"
        case .archive: return "archivebox.fill"
        case .other: return "doc"
        }
    }

    var isPlayable: Bool { self == .video || self == .audio }
}

enum MediaFileTypes {
    static let video: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts",
        "rmvb", "rm", "mpg", "mpeg", "vob", "3gp", "iso", "strm", "asf", "divx", "ogv"
    ]

    static let subtitle: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi", "idx"]

    static let image: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tiff"]

    static let audio: Set<String> = ["mp3", "flac", "wav", "aac", "m4a", "ogg", "ape", "wma", "opus"]

    static let archive: Set<String> = ["zip", "rar", "7z", "tar", "gz"]

    static let document: Set<String> = ["txt", "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "json", "xml", "html"]

    static func kind(for name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if video.contains(ext) { return .video }
        if subtitle.contains(ext) { return .subtitle }
        if image.contains(ext) { return .image }
        if audio.contains(ext) { return .audio }
        if ext == "nfo" { return .nfo }
        if archive.contains(ext) { return .archive }
        if document.contains(ext) { return .document }
        return .other
    }
}

/// 统一的文件条目，本机与所有远程协议共用
struct FileEntry: Identifiable, Hashable, Codable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?
    var kind: FileKind

    var id: String { path }

    init(name: String,
         path: String,
         isDirectory: Bool,
         size: Int64 = 0,
         modified: Date? = nil,
         kind: FileKind? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind ?? MediaFileTypes.kind(for: name, isDirectory: isDirectory)
    }

    var displayName: String { name.isEmpty ? path.lastPathComponent : name }

    var fileExtensionLowercased: String { (name as NSString).pathExtension.lowercased() }
}

/// 视频播放所需的地址与请求头
struct StreamDescriptor: Codable, Hashable {
    var url: URL
    var headers: [String: String]
    var title: String

    init(url: URL, headers: [String: String] = [:], title: String = "") {
        self.url = url
        self.headers = headers
        self.title = title
    }
}

/// 横幅 / 封面等图片引用，可携带鉴权头
struct ImageRef: Codable, Hashable, Identifiable {
    var url: URL
    var headers: [String: String]

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    init(fileURL: URL) {
        self.url = fileURL
        self.headers = [:]
    }

    var id: String { cacheKey }

    var cacheKey: String {
        let headerPart = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        return "\(url.absoluteString)|\(headerPart)"
    }

    var isLocalFile: Bool { url.isFileURL }
}

/// 媒体附属文件（视频 / 字幕）
struct MediaFileRef: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    var size: Int64

    var id: String { path }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var fileExtensionLowercased: String { (name as NSString).pathExtension.lowercased() }
}
