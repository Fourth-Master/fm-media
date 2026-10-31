import Foundation
import Compression

/// SubtitleCat 详情页的下载表单解析
enum SubtitleCatForm {
    struct Form {
        var action: URL
        var body: Data
    }

    static func parse(in html: String, base: URL) -> Form? {
        guard let formRegex = try? NSRegularExpression(pattern: "(?is)<form([^>]*)>(.*?)</form>",
                                                       options: []) else { return nil }
        let ns = html as NSString
        let matches = formRegex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var best: Form?
        var bestScore = -1

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let attributes = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))

            let actionRaw = attributeValue("action", in: attributes) ?? ""
            guard !actionRaw.isEmpty,
                  let action = URL(string: actionRaw, relativeTo: base)?.absoluteURL else { continue }

            let method = (attributeValue("method", in: attributes) ?? "get").lowercased()
            let fields = inputFields(in: inner)
            guard !fields.isEmpty else { continue }

            // 优先带着 subtitle_id / id 或 action 含 download 的表单
            var score = 0
            if action.absoluteString.lowercased().contains("download") { score += 3 }
            if fields.keys.contains(where: { $0.lowercased().contains("subtitle") }) { score += 3 }
            if fields.keys.contains("id") { score += 1 }
            if method == "post" { score += 1 }
            guard score > bestScore else { continue }

            let encoded = fields.map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }.joined(separator: "&")

            if method == "post" {
                best = Form(action: action, body: Data(encoded.utf8))
            } else {
                var components = URLComponents(url: action, resolvingAgainstBaseURL: false)
                let existing = components?.percentEncodedQuery ?? ""
                components?.percentEncodedQuery = existing.isEmpty ? encoded : existing + "&" + encoded
                if let url = components?.url {
                    best = Form(action: url, body: Data())
                }
            }
            bestScore = score
        }
        return best
    }

    private static func attributeValue(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
                                                   options: []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func inputFields(in text: String) -> [String: String] {
        guard let tagRegex = try? NSRegularExpression(pattern: "(?is)<input\\s+([^>]*)>", options: []) else { return [:] }
        let ns = text as NSString
        var fields: [String: String] = [:]
        for match in tagRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 2 else { continue }
            let attributes = ns.substring(with: match.range(at: 1))
            guard let name = attributeValue("name", in: attributes), !name.isEmpty else { continue }
            fields[name] = attributeValue("value", in: attributes) ?? ""
        }
        return fields
    }

    private static func percentEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// gzip 解压（SubtitleCat 部分响应是 gzip）
enum GzipDecoder {
    static func decompressIfNeeded(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            return nil
        }
        let bytes = [UInt8](data.prefix(10))
        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 {
            guard data.count > offset + 2 else { return nil }
            let index = data.startIndex + offset
            let length = Int(data[index]) | (Int(data[index + 1]) << 8)
            offset += 2 + length
        }
        if flags & 0x08 != 0 {
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count else { return nil }

        let deflated = data.subdata(in: (data.startIndex + offset)..<data.endIndex)
        return inflate(deflated)
    }

    private static func inflate(_ data: Data) -> Data? {
        var capacity = max(data.count * 6, 128 * 1024)
        for _ in 0..<7 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                data.withUnsafeBytes { source -> Int in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < capacity {
                return output.prefix(written)
            }
            capacity *= 4
        }
        return nil
    }
}

extension HTMLScraper {
    /// 取页面标题（title / og:title / h1）
    static func firstTitle(in html: String) -> String? {
        let patterns = [
            "(?is)<meta[^>]+property\\s*=\\s*[\"']og:title[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
            "(?is)<title[^>]*>(.*?)</title>",
            "(?is)<h1[^>]*>(.*?)</h1>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = html as NSString
            guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
            let cleaned = stripTags(raw)
                .replacingOccurrences(of: " - Subtitle Cat", with: "")
                .trimmed
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
