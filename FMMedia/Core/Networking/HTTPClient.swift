import Foundation

struct HTTPResponse {
    let data: Data
    let status: Int
    let headerFields: [String: String]

    var isSuccess: Bool { (200..<300).contains(status) }

    var text: String {
        TextDecoding.decode(data)?.text ?? ""
    }

    func json() -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

enum HTTPClient {
    static func request(_ method: String,
                        url: URL,
                        headers: [String: String] = [:],
                        body: Data? = nil,
                        extraAcceptedStatus: Set<Int> = [],
                        timeout: TimeInterval = 30) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.network("服务器未返回有效响应")
            }
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    fields[key.lowercased()] = value
                }
            }
            let result = HTTPResponse(data: data, status: http.statusCode, headerFields: fields)
            if result.isSuccess || extraAcceptedStatus.contains(http.statusCode) {
                return result
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AppError.auth("身份验证失败（HTTP \(http.statusCode)），请检查账号或 Token")
            }
            if http.statusCode == 404 {
                throw AppError.network("资源不存在（HTTP 404）")
            }
            throw AppError.network("服务器返回 HTTP \(http.statusCode)")
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network(describeError(error))
        }
    }

    static func get(_ url: URL,
                    headers: [String: String] = [:],
                    query: [URLQueryItem] = [],
                    timeout: TimeInterval = 30) async throws -> HTTPResponse {
        let finalURL = url.appending(queryItems: query)
        return try await request("GET", url: finalURL, headers: headers, timeout: timeout)
    }

    // MARK: - 工具

    static func basicAuth(user: String, password: String) -> String {
        let raw = "\(user):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    /// 路径编码：`#` `?` 在 URL 中是分隔符，必须显式编码（服务器目录名可能包含它们）
    private static let pathAllowedCharacters: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "#?")
        return set
    }()

    static func encodePath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.map { segment -> String in
            let value = String(segment)
            return value.addingPercentEncoding(withAllowedCharacters: pathAllowedCharacters) ?? value
        }.joined(separator: "/")
    }

    static func url(base: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var baseString = base.trimmed
        guard !baseString.isEmpty else { return nil }
        if !baseString.lowercased().hasPrefix("http://") && !baseString.lowercased().hasPrefix("https://") {
            baseString = "http://" + baseString
        }
        guard var components = URLComponents(string: baseString) else { return nil }
        // 用 percentEncodedPath 承载已编码路径，避免 URLComponents 二次编码或把 # 当片段
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var fullPath = basePath
        if !trimmedPath.isEmpty {
            fullPath += "/" + encodePath(trimmedPath)
        }
        components.percentEncodedPath = fullPath.isEmpty ? "/" : fullPath
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url
    }

    /// 规范化用户输入的服务器地址
    static func normalizeServerAddress(_ raw: String, defaultScheme: String = "http") -> String {
        var text = raw.trimmed
        guard !text.isEmpty else { return "" }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "\(defaultScheme)://\(text)"
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 规范化目录路径：保证以 / 开头、去掉结尾的 /
    static func normalizeDirPath(_ raw: String) -> String {
        var text = raw.trimmed
        guard !text.isEmpty else { return "" }
        if !text.hasPrefix("/") { text = "/" + text }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func formEncoded(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    static func jsonBody(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard !queryItems.isEmpty, var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
