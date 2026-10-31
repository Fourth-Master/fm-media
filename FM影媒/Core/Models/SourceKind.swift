import Foundation

/// 支持的数据源类型
enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case local
    case emby
    case jellyfin
    case fnos
    case zspace
    case aliyun
    case baidu
    case pan115
    case tianyi
    case cmcc
    case pan123
    case guangya
    case webdav
    case smb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "本机目录"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .fnos: return "飞牛影视"
        case .zspace: return "极空间影视"
        case .aliyun: return "阿里云盘"
        case .baidu: return "百度网盘"
        case .pan115: return "115网盘"
        case .tianyi: return "天翼云盘"
        case .cmcc: return "中国移动云盘"
        case .pan123: return "123云盘"
        case .guangya: return "光鸭云盘"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "internaldrive"
        case .emby: return "play.tv"
        case .jellyfin: return "sparkles.tv"
        case .fnos: return "externaldrive.connected.to.line.below"
        case .zspace: return "externaldrive.fill"
        case .aliyun: return "cloud"
        case .baidu: return "cloud.fill"
        case .pan115: return "cloud.sun"
        case .tianyi: return "cloud.bolt"
        case .cmcc: return "cloud.rain"
        case .pan123: return "cloud.moon"
        case .guangya: return "cloud.drizzle"
        case .webdav: return "globe"
        case .smb: return "network"
        }
    }

    /// 媒体服务器（Emby 系）
    var isMediaServer: Bool {
        switch self {
        case .emby, .jellyfin, .fnos, .zspace: return true
        default: return false
        }
    }

    var isCloud: Bool {
        switch self {
        case .aliyun, .baidu, .pan115, .tianyi, .cmcc, .pan123, .guangya: return true
        default: return false
        }
    }

    var isLocal: Bool { self == .local }

    /// 需要 服务器地址 + 账号密码
    var needsServerAddress: Bool {
        switch self {
        case .emby, .jellyfin, .fnos, .zspace, .webdav, .smb: return true
        default: return false
        }
    }
}

enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case recent
    case code
    case title
    case rating
    case size
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最近添加"
        case .code: return "番号"
        case .title: return "标题"
        case .rating: return "评分"
        case .size: return "文件大小"
        case .duration: return "时长"
        }
    }
}

enum LibraryFilter: String, Codable, CaseIterable, Identifiable {
    case all
    case cracked
    case subtitled
    case favorites
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .cracked: return "破解"
        case .subtitled: return "字幕"
        case .favorites: return "收藏"
        case .recent: return "最近"
        }
    }
}
