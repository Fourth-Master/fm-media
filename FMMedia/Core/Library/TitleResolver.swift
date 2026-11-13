import Foundation

// MARK: - 标题显示方式

enum TitleDisplayMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case originalWithPlot
    case titleWithActors
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .originalWithPlot: return "大标题 + 简介"
        case .titleWithActors: return "大标题 + 演员"
        case .custom: return "自定义组合"
        }
    }

    var detail: String {
        switch self {
        case .originalWithPlot: return "大标题字段在下方选择（TITLE / ORIGINALTITLE），小标题截取简介开头"
        case .titleWithActors: return "大标题字段在下方选择（TITLE / ORIGINALTITLE），小标题列出演员"
        case .custom: return "自行勾选字段组合大标题与小标题"
        }
    }
}

/// 可用于组合标题的数据字段
enum TitleField: String, Codable, CaseIterable, Identifiable, Hashable {
    case originalTitle
    case title
    case code
    case plotExcerpt
    case actors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .originalTitle: return "originaltitle（原名）"
        case .title: return "title（标题）"
        case .code: return "番号"
        case .plotExcerpt: return "简介开头"
        case .actors: return "演员"
        }
    }
}

/// 解析后的展示标题
struct DisplayTitle: Equatable {
    var title: String
    var subtitle: String
    /// true 表示数据源缺失，回退成了番号
    var isFallback: Bool
}

enum TitleResolver {
    static let defaultSubtitleFields: [TitleField] = [.plotExcerpt]

    static func resolve(item: MediaItem,
                        mode: TitleDisplayMode,
                        titleField: TitleField,
                        subtitleFields: [TitleField]) -> DisplayTitle {
        switch mode {
        case .custom:
            let composedTitle = text(of: titleField, item: item)
            let composedSubtitle = compose(subtitleFields, item: item)
            if !composedTitle.isEmpty {
                return DisplayTitle(title: composedTitle, subtitle: composedSubtitle, isFallback: false)
            }
            return fallback(item, preferOriginal: true, subtitle: composedSubtitle)

        case .originalWithPlot:
            // 大标题字段由设置选择（TITLE / ORIGINALTITLE），缺失时自动回退
            return fallback(item, preferOriginal: titleField == .originalTitle, subtitle: excerpt(item.plot))

        case .titleWithActors:
            return fallback(item, preferOriginal: titleField == .originalTitle, subtitle: actorText(item))
        }
    }

    // MARK: - 组合

    private static func compose(_ fields: [TitleField], item: MediaItem) -> String {
        var parts: [String] = []
        for field in fields {
            let value = text(of: field, item: item)
            if !value.isEmpty { parts.append(value) }
        }
        return parts.joined(separator: " · ").trimmed
    }

    private static func text(of field: TitleField, item: MediaItem) -> String {
        switch field {
        case .originalTitle:
            return (item.originalTitle ?? "").trimmed
        case .title:
            return hasRealTitle(item) ? item.title.trimmed : ""
        case .code:
            return item.code
        case .plotExcerpt:
            return excerpt(item.plot)
        case .actors:
            return actorText(item)
        }
    }

    // MARK: - 回退

    private static func fallback(_ item: MediaItem,
                                 preferOriginal: Bool,
                                 subtitle: String) -> DisplayTitle {
        let original = (item.originalTitle ?? "").trimmed
        if preferOriginal, !original.isEmpty {
            return DisplayTitle(title: original, subtitle: subtitle, isFallback: false)
        }
        if hasRealTitle(item) {
            return DisplayTitle(title: item.title.trimmed, subtitle: subtitle, isFallback: false)
        }
        if !original.isEmpty {
            return DisplayTitle(title: original, subtitle: subtitle, isFallback: false)
        }
        return DisplayTitle(title: item.code, subtitle: subtitle, isFallback: true)
    }

    /// 扫描器在无 NFO 时会把 title 填成番号展示形式（"CODE" 或 "CODE · 破解 · 字幕"），
    /// 仅完全匹配该形式才视为"没有数据源"。
    /// NFO 的真实标题常以番号开头（如 "MIDA-849 大浴場…"），
    /// 前缀判断会误杀真实标题，导致大标题选 TITLE 时仍显示 originaltitle
    private static func hasRealTitle(_ item: MediaItem) -> Bool {
        let title = item.title.trimmed
        guard !title.isEmpty else { return false }
        let code = item.code.trimmed
        if title.caseInsensitiveCompare(code) == .orderedSame { return false }
        if title.lowercased().hasPrefix(code.lowercased() + " · ") { return false }
        return true
    }

    private static func actorText(_ item: MediaItem) -> String {
        item.actors
            .prefix(3)
            .map { $0.name.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private static func excerpt(_ text: String, limit: Int = 46) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmed
        guard !flat.isEmpty else { return "" }
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
