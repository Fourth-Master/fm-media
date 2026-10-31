import Foundation

/// 番号解析结果
struct MediaCode: Hashable {
    /// 原始名称（不含扩展名）
    let raw: String
    /// 规范化番号，字母大写，例如 ABC-123
    let number: String
    /// -u 破解
    let isCracked: Bool
    /// -c 字幕
    let hasSubtitleTag: Bool
    /// 额外无法识别的后缀片段
    let extraTokens: [String]

    /// 例：ABC-123 · 破解 · 字幕
    var displayName: String {
        var parts = [number]
        if isCracked { parts.append("破解") }
        if hasSubtitleTag { parts.append("字幕") }
        return parts.joined(separator: " · ")
    }

    var flags: [String] {
        var result: [String] = []
        if isCracked { result.append("破解") }
        if hasSubtitleTag { result.append("字幕") }
        return result
    }
}

/// 依据约定解析文件夹 / 文件名：
/// - 基本番号 `ABC-123`
/// - `ABC-123-u` → 破解
/// - `ABC-123-c` → 字幕
/// - `ABC-123-uc` / `-cu` → 破解 + 字幕
/// - u / c 不区分大小写，分隔符支持 `-` `_` `.` 空格
enum MediaCodeParser {
    private static let strictPattern = #"^\s*([A-Za-z]{2,6})[\s._\-]*(\d{2,5})((?:\s*[\s._\-]*\s*[A-Za-z]+)*)\s*$"#

    private static let strictRegex = try? NSRegularExpression(pattern: strictPattern, options: [])

    static let suffixLetters: Set<String> = ["u", "c", "uc", "cu"]

    static func normalize(_ name: String) -> String {
        var text = name.trimmed
        // 去掉扩展名
        if let dot = text.lastIndex(of: "."), text.distance(from: text.startIndex, to: dot) > 0 {
            let ext = String(text[text.index(after: dot)...]).lowercased()
            if MediaFileTypes.video.contains(ext)
                || MediaFileTypes.subtitle.contains(ext)
                || MediaFileTypes.image.contains(ext)
                || ext == "nfo" {
                text = String(text[..<dot])
            }
        }
        return text
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmed
    }

    static func parse(_ rawName: String) -> MediaCode? {
        let text = normalize(rawName)
        guard !text.isEmpty, let regex = strictRegex else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let lettersRange = Range(match.range(at: 1), in: text),
              let digitsRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let letters = String(text[lettersRange]).uppercased()
        let digits = String(text[digitsRange])
        let number = "\(letters)-\(digits)"

        var suffixRange: Range<String.Index>? = nil
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
            suffixRange = Range(match.range(at: 3), in: text)
        }

        var cracked = false
        var subtitled = false
        var extras: [String] = []

        if let suffixRange {
            let suffix = String(text[suffixRange])
            let tokens = suffix
                .components(separatedBy: CharacterSet(charactersIn: "-_. "))
                .map { $0.trimmed.lowercased() }
                .filter { !$0.isEmpty }

            for token in tokens {
                if suffixLetters.contains(token) {
                    if token.contains("u") { cracked = true }
                    if token.contains("c") { subtitled = true }
                } else if token.count <= 2 && (token == "h" || token == "d") {
                    // 忽略无意义的一两个字母噪声
                    extras.append(token)
                } else {
                    extras.append(token)
                }
            }
        }

        return MediaCode(raw: text, number: number, isCracked: cracked, hasSubtitleTag: subtitled, extraTokens: extras)
    }

    /// 在任意文本中查找首个番号（用于 Emby 路径、文件名带前缀等场景）
    static func find(in text: String) -> MediaCode? {
        if let direct = parse(text) { return direct }
        let pattern = #"([A-Za-z]{2,6})[\s._\-]*(\d{2,5})([\s._\-]*(?:u|c|uc|cu))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }
        return parse(String(text[fullRange]))
    }

    /// 判断文件是否属于某个番号（同番号、忽略 -u/-c 后缀差异）
    static func belongs(fileName: String, to code: String) -> Bool {
        guard let parsed = parse(fileName) else { return false }
        return parsed.number.caseInsensitiveCompare(code) == .orderedSame
    }
}
