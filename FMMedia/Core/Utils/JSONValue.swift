import Foundation

/// 容错的 JSON 取值工具，用于解析各网盘 / 服务器返回的不规则结构
enum JSONValue {
    static func dict(_ any: Any?) -> [String: Any] {
        any as? [String: Any] ?? [:]
    }

    static func array(_ any: Any?) -> [Any] {
        if let array = any as? [Any] { return array }
        if let dict = any as? [String: Any] { return [dict] }
        return []
    }

    static func dictArray(_ any: Any?) -> [[String: Any]] {
        array(any).compactMap { $0 as? [String: Any] }
    }

    static func string(_ any: Any?) -> String? {
        if let value = any as? String { return value }
        if let value = any as? NSNumber { return value.stringValue }
        if let value = any as? Bool { return value ? "true" : "false" }
        return nil
    }

    static func string(_ dict: [String: Any], _ key: String) -> String? {
        string(dict[key])
    }

    static func int64(_ any: Any?) -> Int64? {
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? NSNumber { return value.int64Value }
        if let value = any as? String { return Int64(value) }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        int64(any).map { Int($0) }
    }

    static func double(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value) }
        return nil
    }

    static func bool(_ any: Any?) -> Bool? {
        if let value = any as? Bool { return value }
        if let value = any as? NSNumber { return value.boolValue }
        if let value = any as? String { return value == "true" || value == "1" }
        return nil
    }

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 深度查找第一个匹配 key 的字符串值
    static func deepString(_ any: Any?, keys: Set<String>) -> String? {
        if let dict = any as? [String: Any] {
            for (key, value) in dict where keys.contains(key.lowercased()) {
                if let text = string(value), !text.isEmpty { return text }
            }
            for value in dict.values {
                if let found = deepString(value, keys: keys) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = deepString(value, keys: keys) { return found }
            }
        }
        return nil
    }
}
