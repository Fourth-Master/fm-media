import Foundation

/// WebDAV 客户端（PROPFIND / GET / PUT / MKCOL / DELETE / MOVE / COPY）
final class WebDAVProvider: RemoteFileProvider {
    let config: MediaSourceConfig

    var capabilities: ProviderCapabilities {
        var caps = ProviderCapabilities.full
        caps.cheapStream = true
        return caps
    }

    private let base: String
    private let basePath: String
    private let authHeaders: [String: String]

    init(config: MediaSourceConfig) {
        self.config = config
        self.base = HTTPClient.normalizeServerAddress(config.baseURL)
        let path = URL(string: base)?.path ?? ""
        self.basePath = path.hasSuffix("/") ? String(path.dropLast()) : path

        var headers = ["Accept": "*/*"]
        if !config.username.isEmpty || !config.secret.isEmpty {
            headers["Authorization"] = HTTPClient.basicAuth(user: config.username, password: config.secret)
        }
        self.authHeaders = headers
    }

    /// 支持「起始目录」：添加来源时指定的子目录
    var rootPath: String {
        let configured = HTTPClient.normalizeDirPath(config.extra["path"] ?? "")
        return configured.isEmpty ? "/" : configured
    }

    func list(path: String) async throws -> [FileEntry] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getcontenttype/>
          </d:prop>
        </d:propfind>
        """
        guard let url = HTTPClient.url(base: base, path: path) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        var headers = authHeaders
        headers["Depth"] = "1"
        headers["Content-Type"] = "application/xml; charset=utf-8"

        let response = try await HTTPClient.request("PROPFIND",
                                                    url: url,
                                                    headers: headers,
                                                    body: Data(body.utf8),
                                                    extraAcceptedStatus: [207])
        let entries = WebDAVMultistatusParser.parse(data: response.data)
        let normalizedSelf = normalize(path)

        var results: [FileEntry] = []
        for raw in entries {
            let relative = relativePath(fromHref: raw.href)
            if normalize(relative) == normalizedSelf { continue }
            if relative.isEmpty || relative == "/" { continue }
            let name = raw.displayName?.trimmed.isEmpty == false
                ? (raw.displayName ?? "")
                : (relative as NSString).lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            results.append(FileEntry(name: name,
                                     path: relative,
                                     isDirectory: raw.isDirectory,
                                     size: raw.contentLength,
                                     modified: raw.modified))
        }

        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func stream(path: String) async throws -> StreamDescriptor {
        guard let url = HTTPClient.url(base: base, path: path) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        return StreamDescriptor(url: url, headers: authHeaders, title: path.lastPathComponent)
    }

    func makeDirectory(path: String) async throws {
        guard let url = HTTPClient.url(base: base, path: path) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        _ = try await HTTPClient.request("MKCOL", url: url, headers: authHeaders, extraAcceptedStatus: [201, 405])
    }

    func remove(path: String) async throws {
        guard let url = HTTPClient.url(base: base, path: path) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        _ = try await HTTPClient.request("DELETE", url: url, headers: authHeaders, extraAcceptedStatus: [204, 404])
    }

    func move(path: String, toDirectory: String) async throws {
        let name = (path as NSString).lastPathComponent
        try await moveItem(from: path, to: join(directory: toDirectory, name: name))
    }

    func copy(path: String, toDirectory: String) async throws {
        let name = (path as NSString).lastPathComponent
        guard let url = HTTPClient.url(base: base, path: path),
              let destination = HTTPClient.url(base: base, path: join(directory: toDirectory, name: name)) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        var headers = authHeaders
        headers["Destination"] = destination.absoluteString
        headers["Overwrite"] = "F"
        _ = try await HTTPClient.request("COPY", url: url, headers: headers, extraAcceptedStatus: [201, 204])
    }

    func rename(path: String, to newName: String) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try await moveItem(from: path, to: join(directory: directory, name: newName.sanitizedFileName))
    }

    private func moveItem(from path: String, to destinationPath: String) async throws {
        guard let url = HTTPClient.url(base: base, path: path),
              let destination = HTTPClient.url(base: base, path: destinationPath) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        var headers = authHeaders
        headers["Destination"] = destination.absoluteString
        headers["Overwrite"] = "F"
        _ = try await HTTPClient.request("MOVE", url: url, headers: headers, extraAcceptedStatus: [201, 204])
    }

    func download(path: String, to destinationDirectory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = HTTPClient.url(base: base, path: path) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        let name = (path as NSString).lastPathComponent
        return try await HTTPFileTransfer.download(url: url,
                                                   headers: authHeaders,
                                                   to: destinationDirectory,
                                                   preferredName: name,
                                                   progress: progress)
    }

    func upload(localURL: URL, to directoryPath: String, progress: @escaping (Double) -> Void) async throws -> String {
        let targetPath = join(directory: directoryPath, name: localURL.lastPathComponent)
        guard let url = HTTPClient.url(base: base, path: targetPath) else {
            throw AppError.notConfigured("WebDAV 地址无效")
        }
        var headers = authHeaders
        headers["Content-Type"] = "application/octet-stream"
        try await HTTPFileTransfer.upload(url: url, method: "PUT", headers: headers, from: localURL, progress: progress)
        return targetPath
    }

    // MARK: - 路径处理

    private func normalize(_ path: String) -> String {
        var value = path
        if value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { value = "/" }
        return value
    }

    private func join(directory: String, name: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + name }
        var dir = directory
        if !dir.hasSuffix("/") { dir += "/" }
        return dir + name
    }

    private func relativePath(fromHref href: String) -> String {
        var pathPart = href
        if href.lowercased().hasPrefix("http") {
            pathPart = URL(string: href)?.path ?? href
        }
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        var value = decoded
        if !basePath.isEmpty, value.hasPrefix(basePath) {
            value.removeFirst(basePath.count)
        }
        if value.isEmpty { value = "/" }
        if !value.hasPrefix("/") { value = "/" + value }
        return normalize(value)
    }
}

struct WebDAVEntry {
    var href: String = ""
    var displayName: String? = nil
    var isDirectory: Bool = false
    var contentLength: Int64 = 0
    var modified: Date? = nil
}

final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var current = WebDAVEntry()
    private var text = ""
    private var inResponse = false
    private var inCollection = false

    static func parse(data: Data) -> [WebDAVEntry] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.entries
    }

    private func localName(_ name: String) -> String {
        if let range = name.range(of: ":") {
            return String(name[range.upperBound...]).lowercased()
        }
        return name.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = localName(elementName)
        text = ""
        switch tag {
        case "response":
            current = WebDAVEntry()
            inResponse = true
        case "collection":
            inCollection = true
        case "resourcetype":
            inCollection = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = localName(elementName)
        let value = text.trimmed
        switch tag {
        case "href":
            if value.hasPrefix("http") {
                current.href = URL(string: value)?.path ?? value
            } else {
                current.href = value
            }
        case "displayname":
            current.displayName = value
        case "getcontentlength":
            current.contentLength = Int64(value) ?? 0
        case "getlastmodified":
            current.modified = WebDAVMultistatusParser.httpDate(value)
        case "resourcetype":
            current.isDirectory = inCollection
        case "response":
            if inResponse {
                entries.append(current)
                inResponse = false
            }
        default:
            break
        }
        text = ""
    }

    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
