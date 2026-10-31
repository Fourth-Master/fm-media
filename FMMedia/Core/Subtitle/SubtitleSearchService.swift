import Foundation

/// 字幕搜索服务：迅雷字幕接口 + SubtitleCat
///
/// - `https://api-shoulei-ssl.xunlei.com/oracle/subtitle?name=番号`
/// - `https://subtitlecat.com/index.php?search=番号`
final class SubtitleSearchService {
    static let shared = SubtitleSearchService()

    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    struct SearchOptions {
        var xunleiEnabled = true
        var subtitlecatEnabled = true
        var language = "zh"
    }

    func search(code: String, options: SearchOptions) async -> [SubtitleSearchResult] {
        let query = code.trimmed
        guard !query.isEmpty else { return [] }

        var results: [SubtitleSearchResult] = []

        if options.subtitlecatEnabled {
            if let cat = try? await searchSubtitleCat(query) {
                results.append(contentsOf: cat)
            }
        }
        if options.xunleiEnabled {
            if let lei = try? await searchXunlei(query) {
                results.append(contentsOf: lei)
            }
        }

        // 语言优先
        let preferred = options.language.lowercased()
        results.sort { lhs, rhs in
            let lhsMatch = lhs.language.lowercased().contains(preferred) || lhs.language.contains("中")
            let rhsMatch = rhs.language.lowercased().contains(preferred) || rhs.language.contains("中")
            if lhsMatch != rhsMatch { return lhsMatch }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return results
    }

    // MARK: - 迅雷

    private func searchXunlei(_ code: String) async throws -> [SubtitleSearchResult] {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        guard let url = URL(string: "https://api-shoulei-ssl.xunlei.com/oracle/subtitle?name=\(encoded)") else {
            return []
        }
        let response = try await HTTPClient.request("GET",
                                                    url: url,
                                                    headers: ["Accept": "application/json", "User-Agent": userAgent])
        guard let json = JSONValue.parse(response.data) else { return [] }

        var found: [SubtitleSearchResult] = []
        var seen = Set<String>()

        func harvest(_ node: Any) {
            if let dict = node as? [String: Any] {
                var download: String?
                for key in ["url", "surl", "download_url", "downloadUrl", "download", "link", "src"] {
                    if let value = JSONValue.string(dict[key]), value.lowercased().hasPrefix("http") {
                        download = value
                        break
                    }
                }
                if let download, let downloadURL = URL(string: download), !seen.contains(download) {
                    seen.insert(download)
                    let title = JSONValue.string(dict["name"])
                        ?? JSONValue.string(dict["title"])
                        ?? JSONValue.string(dict["filename"])
                        ?? JSONValue.string(dict["file_name"])
                        ?? code
                    let language = JSONValue.string(dict["languagename"])
                        ?? JSONValue.string(dict["language"])
                        ?? JSONValue.string(dict["lang"])
                        ?? detectLanguage(title)
                    let format = JSONValue.string(dict["format"])
                        ?? JSONValue.string(dict["ext"])
                        ?? (download as NSString).pathExtension.lowercased()
                    found.append(SubtitleSearchResult(title: title,
                                                      provider: "迅雷字幕",
                                                      language: language,
                                                      detailURL: nil,
                                                      downloadURL: downloadURL,
                                                      format: format.isEmpty ? "srt" : format.uppercased(),
                                                      note: ""))
                }
                for value in dict.values { harvest(value) }
            } else if let array = node as? [Any] {
                for value in array { harvest(value) }
            }
        }

        harvest(json)
        return found
    }

    // MARK: - SubtitleCat

    /// 搜索页 → 详情页（/subs/{id}/{番号}.html）→ 每个语言的字幕文件（/subs/{id}/{番号}-zh-CN.srt）
    private func searchSubtitleCat(_ code: String) async throws -> [SubtitleSearchResult] {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        guard let url = URL(string: "https://www.subtitlecat.com/index.php?search=\(encoded)") else { return [] }
        let response = try await HTTPClient.request("GET",
                                                    url: url,
                                                    headers: ["User-Agent": userAgent, "Accept": "text/html"],
                                                    timeout: 40)
        let html = response.text
        guard !html.isEmpty else { return [] }

        var detailURLs: [URL] = []
        var seen = Set<String>()
        for link in HTMLScraper.links(in: html) {
            let href = link.href
            guard href.lowercased().contains("subs/"), href.lowercased().hasSuffix(".html") else { continue }
            guard let detail = URL(string: href, relativeTo: URL(string: "https://www.subtitlecat.com"))?.absoluteURL else { continue }
            let key = detail.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            detailURLs.append(detail)
            if detailURLs.count >= 12 { break }
        }
        guard !detailURLs.isEmpty else { return [] }

        var results: [SubtitleSearchResult] = []
        await withTaskGroup(of: [SubtitleSearchResult].self) { group in
            for detail in detailURLs {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.resolveSubtitleCatDetail(detail)
                }
            }
            for await items in group {
                results.append(contentsOf: items)
            }
        }

        results.sort { lhs, rhs in
            let lhsChinese = lhs.language.contains("中")
            let rhsChinese = rhs.language.contains("中")
            if lhsChinese != rhsChinese { return lhsChinese }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return results
    }

    /// 详情页里直接列出各语言字幕文件，例如 /subs/1545/DLDSS-504-zh-CN.srt
    private func resolveSubtitleCatDetail(_ detailURL: URL) async -> [SubtitleSearchResult] {
        guard let response = try? await HTTPClient.request("GET",
                                                           url: detailURL,
                                                           headers: ["User-Agent": userAgent, "Accept": "text/html"],
                                                           timeout: 30) else { return [] }
        let html = response.text
        guard !html.isEmpty else { return [] }

        let pageTitle = HTMLScraper.firstTitle(in: html) ?? detailURL.lastPathComponent

        var results: [SubtitleSearchResult] = []
        var seen = Set<String>()

        for link in HTMLScraper.links(in: html) {
            let href = link.href
            let ext = (href as NSString).pathExtension.lowercased()
            guard ["srt", "ass", "ssa", "vtt"].contains(ext), href.lowercased().contains("subs/") else { continue }
            guard let fileURL = URL(string: href, relativeTo: detailURL)?.absoluteURL else { continue }
            let key = fileURL.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let fileName = fileURL.lastPathComponent
            let language = languageLabel(forFileName: fileName)
            results.append(SubtitleSearchResult(title: "\(pageTitle) · \(language)",
                                                provider: "SubtitleCat",
                                                language: language,
                                                detailURL: detailURL,
                                                downloadURL: fileURL,
                                                format: ext.uppercased(),
                                                note: fileName))
        }

        // 兜底：表单下载（部分条目需要 POST）
        if results.isEmpty, let form = SubtitleCatForm.parse(in: html, base: detailURL) {
            results.append(SubtitleSearchResult(title: pageTitle,
                                                provider: "SubtitleCat",
                                                language: languageLabel(forFileName: pageTitle),
                                                detailURL: detailURL,
                                                downloadURL: form.action,
                                                format: "SRT",
                                                note: "表单下载",
                                                postBody: form.body))
        }
        return results
    }

    /// 从文件名判断语言：DLDSS-504-zh-CN.srt → 简体中文
    private func languageLabel(forFileName fileName: String) -> String {
        let lower = fileName.lowercased()
        let rules: [(keys: [String], label: String)] = [
            (["zh-cn", "zh_cn", "zh-hans", "chs", "-cn.", "chinese (simplified)"], "简体中文"),
            (["zh-tw", "zh_tw", "zh-hant", "cht", "chinese (traditional)"], "繁体中文"),
            (["zh", "chinese", "chi"], "中文"),
            (["en.", "eng", "english"], "English"),
            (["ja", "jpn", "japanese"], "日本語"),
            (["ko", "kor", "korean"], "한국어"),
            (["fr", "fre", "french"], "Français"),
            (["de", "ger", "german"], "Deutsch"),
            (["es", "spa", "spanish"], "Español"),
            (["ru", "rus", "russian"], "Русский"),
            (["pt", "por", "portuguese"], "Português"),
            (["it", "ita", "italian"], "Italiano")
        ]
        for rule in rules {
            for key in rule.keys where lower.contains(key) {
                return rule.label
            }
        }
        return "未知"
    }

    // MARK: - 下载

    struct DownloadedSubtitle {
        var text: String
        var encoding: String.Encoding
        var fileName: String
        var localURL: URL?
    }

    func download(_ result: SubtitleSearchResult) async throws -> DownloadedSubtitle {
        var targetURL = result.downloadURL
        var postBody = result.postBody

        if targetURL == nil, let detailURL = result.detailURL {
            if let detail = await resolveSubtitleCatDetail(detailURL).first(where: { $0.downloadURL != nil }) {
                targetURL = detail.downloadURL
                postBody = detail.postBody
            }
        }
        guard let targetURL else {
            throw AppError.network("该字幕没有可用的下载地址")
        }

        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": "https://subtitlecat.com/",
            "Accept": "*/*"
        ]
        var body: Data? = nil
        if let postBody {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = postBody
        }

        let response = try await HTTPClient.request(postBody == nil ? "GET" : "POST",
                                                    url: targetURL,
                                                    headers: headers,
                                                    body: body,
                                                    timeout: 60)
        // gzip 解压（SubtitleCat 部分文件是压缩传输）
        let raw = GzipDecoder.decompressIfNeeded(response.data) ?? response.data
        guard let decoded = TextDecoding.decode(raw), !decoded.text.isEmpty else {
            throw AppError.unsupported("该字幕可能是压缩包或未知编码，请在浏览器中下载后使用「导入字幕」")
        }
        guard !SubtitleParser.parse(text: decoded.text).isEmpty else {
            throw AppError.unsupported("下载内容不是有效字幕文件，请尝试其他字幕")
        }

        let base = result.title.sanitizedFileName
        let fileName = "\(base).srt"
        var savedURL: URL? = nil
        let destination = FileStore.uniqueDestination(for: fileName, in: FileStore.subtitles)
        if let data = decoded.text.data(using: .utf8) {
            try? data.write(to: destination, options: .atomic)
            savedURL = destination
        }

        return DownloadedSubtitle(text: decoded.text,
                                  encoding: decoded.encoding,
                                  fileName: fileName,
                                  localURL: savedURL)
    }

    // MARK: - 工具

    func detectLanguage(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("chs") || text.contains("简") { return "简体中文" }
        if lower.contains("cht") || text.contains("繁") { return "繁体中文" }
        if lower.contains("eng") || lower.contains("english") || text.contains("英文") { return "English" }
        if lower.contains("jpn") || lower.contains("japanese") || text.contains("日") { return "日本語" }
        if lower.contains("kor") || text.contains("韩") { return "한국어" }
        return "中文"
    }
}

struct SubtitleSearchResult: Identifiable, Hashable {
    var title: String
    var provider: String
    var language: String
    var detailURL: URL?
    var downloadURL: URL?
    var format: String
    var note: String
    /// 需要 POST 才能拿到字幕文件时使用（SubtitleCat）
    var postBody: Data? = nil

    var id: String {
        "\(provider)|\(downloadURL?.absoluteString ?? detailURL?.absoluteString ?? title)"
    }
}

/// 轻量 HTML 解析（避免引入第三方库）
enum HTMLScraper {
    struct Link: Hashable {
        var href: String
        var text: String
    }

    static func links(in html: String) -> [Link] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                                   options: []) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        var result: [Link] = []
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let href = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            result.append(Link(href: href, text: stripTags(inner)))
        }
        return result
    }

    static func stripTags(_ html: String) -> String {
        var output = ""
        var inside = false
        for character in html {
            if character == "<" { inside = true }
            else if character == ">" { inside = false }
            else if !inside { output.append(character) }
        }
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }
}
