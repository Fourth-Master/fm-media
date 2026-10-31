import Foundation

enum TextDecoding {
    static let gb18030: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static let big5: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )

    /// 常见的字幕编码，按优先级尝试
    static let candidates: [String.Encoding] = [
        .utf8, gb18030, big5, .utf16, .utf16LittleEndian, .utf16BigEndian,
        String.Encoding(rawValue: 0x80000632), // GBK
        .isoLatin1
    ]

    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return (text, .utf8)
            }
        }
        if data.starts(with: [0xFF, 0xFE]) {
            if let text = String(data: data, encoding: .utf16LittleEndian) {
                return (text, .utf16LittleEndian)
            }
        }
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return (text, encoding)
            }
        }
        return nil
    }

    static func decodeFile(at url: URL) -> (text: String, encoding: String.Encoding)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var pathExtensionLowercased: String {
        (self as NSString).pathExtension.lowercased()
    }

    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }

    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }

    var deletingLastPathComponent: String {
        (self as NSString).deletingLastPathComponent
    }

    /// 去掉 Windows / POSIX 非法字符，用于文件名
    var sanitizedFileName: String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        let cleaned = components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmed.isEmpty ? "未命名" : cleaned.trimmed
    }

    func containsIgnoringCase(_ other: String) -> Bool {
        range(of: other, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension Int64 {
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    var timecode: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

extension Date {
    var shortText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: self)
    }

    var dayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}

extension Array where Element: Equatable {
    mutating func toggleMembership(_ element: Element) {
        if let index = firstIndex(of: element) {
            remove(at: index)
        } else {
            append(element)
        }
    }
}

extension Set {
    mutating func toggleMembership(_ element: Element) {
        if contains(element) {
            remove(element)
        } else {
            insert(element)
        }
    }
}
