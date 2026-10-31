import Foundation

/// 云盘接入能力
enum CloudSupport: Equatable {
    case openAPI       // 已实现开放接口（浏览 / 播放 / 下载）
    case experimental  // 接口可用但依赖账号权限，可能不稳定
    case webdavOnly    // 官方未开放接口，建议通过 WebDAV 接入

    var title: String {
        switch self {
        case .openAPI: return "开放接口"
        case .experimental: return "实验性"
        case .webdavOnly: return "建议 WebDAV"
        }
    }
}

extension SourceKind {
    var cloudSupport: CloudSupport {
        switch self {
        case .aliyun, .pan123, .baidu: return .openAPI
        case .pan115: return .experimental
        case .tianyi, .cmcc, .guangya: return .webdavOnly
        default: return .openAPI
        }
    }
}

/// 阿里云盘 / 百度网盘 / 115 / 天翼 / 移动 / 123 / 光鸭
///
/// 说明：云盘开放接口需要应用授权（client_id / access_token），
/// 此处使用用户自行申请或从网页端获取的 Token 进行直连。
final class CloudDriveProvider: RemoteFileProvider {
    let config: MediaSourceConfig
    let capabilities: ProviderCapabilities = ProviderCapabilities(read: true, download: true)

    private let kind: SourceKind
    private let token: String
    private var driveIdCache: String?

    init(config: MediaSourceConfig) {
        self.config = config
        self.kind = config.kind
        self.token = config.secret
    }

    var rootPath: String {
        switch kind {
        case .aliyun: return "/root"
        case .pan123, .pan115: return "/0"
        case .baidu: return "/"
        default: return "/"
        }
    }

    func list(path: String) async throws -> [FileEntry] {
        switch kind {
        case .aliyun:
            return try await listAliyun(parentID: identifier(path))
        case .pan123:
            return try await listPan123(parentID: identifier(path))
        case .baidu:
            return try await listBaidu(directory: path.isEmpty ? "/" : path)
        case .pan115:
            return try await listPan115(cid: identifier(path))
        case .tianyi:
            throw AppError.unsupported("天翼云盘开放接口需要签名校验，请使用「WebDAV」方式连接同一账号。")
        case .cmcc:
            throw AppError.unsupported("中国移动云盘开放接口需要签名校验，请使用「WebDAV」方式连接同一账号。")
        case .guangya:
            throw AppError.unsupported("光鸭云盘暂未公开标准接口，请使用「WebDAV」方式连接。")
        default:
            throw AppError.unsupported("该来源不支持浏览")
        }
    }

    func stream(path: String) async throws -> StreamDescriptor {
        switch kind {
        case .aliyun:
            let url = try await aliyunDownloadURL(fileID: identifier(path))
            return StreamDescriptor(url: url, title: path.lastPathComponent)
        case .pan123:
            let url = try await pan123DownloadURL(fileID: identifier(path))
            return StreamDescriptor(url: url, title: path.lastPathComponent)
        case .baidu:
            let (url, headers) = try await baiduDownloadURL(fsID: identifier(path))
            return StreamDescriptor(url: url, headers: headers, title: path.lastPathComponent)
        case .pan115:
            let url = try await pan115DownloadURL(pickCode: identifier(path))
            return StreamDescriptor(url: url, title: path.lastPathComponent)
        default:
            throw AppError.unsupported("该云盘暂不支持直接播放，请使用 WebDAV 接入")
        }
    }

    // MARK: - 阿里云盘

    private var aliyunBase: String { config.extra["apiBase"] ?? "https://openapi.alipan.com" }
    private var aliyunHeaders: [String: String] {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let deviceId = config.extra["deviceId"], !deviceId.isEmpty {
            headers["x-device-id"] = deviceId
        }
        return headers
    }

    private func aliyunDriveId() async throws -> String {
        if let cached = driveIdCache { return cached }
        if let stored = config.extra["driveId"], !stored.isEmpty {
            driveIdCache = stored
            return stored
        }
        guard let url = URL(string: aliyunBase + "/adrive/v1.0/user/getDriveInfo") else {
            throw AppError.notConfigured("阿里云盘接口地址无效")
        }
        let response = try await HTTPClient.request("POST", url: url, headers: aliyunHeaders, body: try HTTPClient.jsonBody([:]))
        let json = JSONValue.dict(JSONValue.parse(response.data))
        guard let driveId = JSONValue.string(json["default_drive_id"]) else {
            throw AppError.auth("无法获取阿里云盘默认空间，请检查 Token")
        }
        driveIdCache = driveId
        return driveId
    }

    private func listAliyun(parentID: String) async throws -> [FileEntry] {
        let driveId = try await aliyunDriveId()
        guard let url = URL(string: aliyunBase + "/adrive/v1.0/openFile/list") else {
            throw AppError.notConfigured("阿里云盘接口地址无效")
        }
        let body = try HTTPClient.jsonBody([
            "drive_id": driveId,
            "parent_file_id": parentID,
            "limit": 200,
            "marker": "",
            "order_by": "name",
            "order_direction": "ASC",
            "fields": "*"
        ])
        let response = try await HTTPClient.request("POST", url: url, headers: aliyunHeaders, body: body)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("阿里云盘返回数据无法解析")
        }
        let items = JSONValue.dictArray(JSONValue.dict(json)["items"])
        return items.compactMap { item -> FileEntry? in
            guard let fileId = JSONValue.string(item["file_id"]),
                  let name = JSONValue.string(item["name"]) else { return nil }
            let isFolder = JSONValue.string(item["type"]) == "folder"
            return FileEntry(name: name,
                             path: "/\(fileId)",
                             isDirectory: isFolder,
                             size: JSONValue.int64(item["size"]) ?? 0,
                             modified: parseISODate(JSONValue.string(item["updated_at"])))
        }
        .sorted(by: fileEntrySort)
    }

    private func aliyunDownloadURL(fileID: String) async throws -> URL {
        let driveId = try await aliyunDriveId()
        guard let url = URL(string: aliyunBase + "/adrive/v1.0/openFile/getDownloadUrl") else {
            throw AppError.notConfigured("阿里云盘接口地址无效")
        }
        let body = try HTTPClient.jsonBody([
            "drive_id": driveId,
            "file_id": fileID,
            "expire_sec": 14400
        ])
        let response = try await HTTPClient.request("POST", url: url, headers: aliyunHeaders, body: body)
        let json = JSONValue.dict(JSONValue.parse(response.data))
        guard let raw = JSONValue.string(json["url"]), let streamURL = URL(string: raw) else {
            throw AppError.network("无法获取阿里云盘下载地址")
        }
        return streamURL
    }

    // MARK: - 123 云盘

    private var pan123Base: String { config.extra["apiBase"] ?? "https://open-api.123pan.com" }
    private var pan123Headers: [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Platform": "open_platform",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
    }

    private func listPan123(parentID: String) async throws -> [FileEntry] {
        guard let url = URL(string: pan123Base + "/api/v1/file/list")?.appending(queryItems: [
            URLQueryItem(name: "parentFileId", value: parentID),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "type", value: "0"),
            URLQueryItem(name: "orderBy", value: "file_name"),
            URLQueryItem(name: "orderDirection", value: "asc")
        ]) else {
            throw AppError.notConfigured("123 云盘接口地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: pan123Headers)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("123 云盘返回数据无法解析")
        }
        let root = JSONValue.dict(json)
        if let code = JSONValue.int(root["code"]), code != 0 {
            throw AppError.auth(JSONValue.string(root["message"]) ?? "123 云盘请求失败")
        }
        let list = JSONValue.dictArray(JSONValue.dict(root["data"])["fileList"])
        return list.compactMap { item -> FileEntry? in
            guard let fileId = JSONValue.int64(item["fileId"]),
                  let name = JSONValue.string(item["fileName"]) else { return nil }
            let type = JSONValue.int(item["type"]) ?? 0
            let isFolder = type == 1
            return FileEntry(name: name,
                             path: "/\(fileId)",
                             isDirectory: isFolder,
                             size: JSONValue.int64(item["size"]) ?? 0,
                             modified: nil)
        }
        .sorted(by: fileEntrySort)
    }

    private func pan123DownloadURL(fileID: String) async throws -> URL {
        guard let url = URL(string: pan123Base + "/api/v1/file/download_info")?.appending(queryItems: [
            URLQueryItem(name: "fileId", value: fileID)
        ]) else {
            throw AppError.notConfigured("123 云盘接口地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: pan123Headers)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("123 云盘返回数据无法解析")
        }
        let data = JSONValue.dict(JSONValue.dict(json)["data"])
        guard let raw = JSONValue.string(data["downloadUrl"]), let streamURL = URL(string: raw) else {
            throw AppError.network("无法获取 123 云盘下载地址")
        }
        return streamURL
    }

    // MARK: - 百度网盘

    private var baiduBase: String { config.extra["apiBase"] ?? "https://pan.baidu.com/rest/2.0/xpan" }
    private var baiduHeaders: [String: String] {
        ["User-Agent": "pan.baidu.com", "Accept": "application/json"]
    }

    private func listBaidu(directory: String) async throws -> [FileEntry] {
        guard let url = URL(string: baiduBase + "/file")?.appending(queryItems: [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "dir", value: directory),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "order", value: "name")
        ]) else {
            throw AppError.notConfigured("百度网盘接口地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: baiduHeaders)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("百度网盘返回数据无法解析")
        }
        let root = JSONValue.dict(json)
        if let errno = JSONValue.int(root["errno"]), errno != 0 {
            throw AppError.auth("百度网盘返回错误码 \(errno)，请检查 access_token 或授权范围")
        }
        return JSONValue.dictArray(root["list"]).compactMap { item -> FileEntry? in
            guard let name = JSONValue.string(item["server_filename"]),
                  let fsId = JSONValue.int64(item["fs_id"]) else { return nil }
            let isFolder = JSONValue.bool(item["isdir"]) ?? false
            let realPath = JSONValue.string(item["path"]) ?? directory
            let entryPath = isFolder ? realPath : "/fsid-\(fsId)"
            return FileEntry(name: name,
                             path: entryPath,
                             isDirectory: isFolder,
                             size: JSONValue.int64(item["size"]) ?? 0,
                             modified: JSONValue.int64(item["server_mtime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        .sorted(by: fileEntrySort)
    }

    private func baiduDownloadURL(fsID: String) async throws -> (URL, [String: String]) {
        let fsIDPath = fsID.hasPrefix("fsid-") ? String(fsID.dropFirst("fsid-".count)) : fsID
        guard let url = URL(string: baiduBase + "/multimedia")?.appending(queryItems: [
            URLQueryItem(name: "method", value: "filemetas"),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "fsids", value: "[\(fsIDPath)]"),
            URLQueryItem(name: "dlink", value: "1")
        ]) else {
            throw AppError.notConfigured("百度网盘接口地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: baiduHeaders)
        let json = JSONValue.dict(JSONValue.parse(response.data))
        let list = JSONValue.dictArray(json["list"])
        guard let raw = list.first.flatMap({ JSONValue.string($0["dlink"]) }),
              let streamURL = URL(string: raw) else {
            throw AppError.network("无法获取百度网盘下载地址")
        }
        return (streamURL, baiduHeaders)
    }

    // MARK: - 115 网盘

    private var pan115Base: String { config.extra["apiBase"] ?? "https://proapi.115.com" }
    private var pan115Headers: [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/json", "Content-Type": "application/json"]
    }

    private func listPan115(cid: String) async throws -> [FileEntry] {
        guard let url = URL(string: pan115Base + "/open/ufile/files")?.appending(queryItems: [
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "asc", value: "1"),
            URLQueryItem(name: "o", value: "file_name")
        ]) else {
            throw AppError.notConfigured("115 网盘接口地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: pan115Headers)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("115 网盘返回数据无法解析")
        }
        let root = JSONValue.dict(json)
        if let state = JSONValue.bool(root["state"]), state == false {
            throw AppError.auth(JSONValue.string(root["message"]) ?? "115 网盘授权失败")
        }
        let list = JSONValue.dictArray(root["data"] ?? root["files"])
        return list.compactMap { item -> FileEntry? in
            guard let name = JSONValue.string(item["n"]) ?? JSONValue.string(item["file_name"]),
                  let fid = JSONValue.int64(item["fid"]) ?? JSONValue.int64(item["file_id"]) else { return nil }
            let ico = JSONValue.string(item["ico"]) ?? ""
            let isFolder = ico.contains("folder") || JSONValue.int(item["ftype"]) == 1
            let pickCode = JSONValue.string(item["pc"]) ?? JSONValue.string(item["pick_code"]) ?? "\(fid)"
            return FileEntry(name: name,
                             path: isFolder ? "/\(fid)" : "/pc-\(pickCode)",
                             isDirectory: isFolder,
                             size: JSONValue.int64(item["s"]) ?? JSONValue.int64(item["size"]) ?? 0,
                             modified: JSONValue.int64(item["mtime"] ?? item["u_time"]).map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        .sorted(by: fileEntrySort)
    }

    private func pan115DownloadURL(pickCode: String) async throws -> URL {
        guard let url = URL(string: pan115Base + "/open/ufile/downurl") else {
            throw AppError.notConfigured("115 网盘接口地址无效")
        }
        let body = try HTTPClient.jsonBody(["pick_code": pickCode])
        let response = try await HTTPClient.request("POST", url: url, headers: pan115Headers, body: body)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("115 网盘返回数据无法解析")
        }
        guard let raw = JSONValue.deepString(json, keys: ["url"]), let streamURL = URL(string: raw) else {
            throw AppError.network("无法获取 115 网盘下载地址")
        }
        return streamURL
    }

    // MARK: - 工具

    private func identifier(_ path: String) -> String {
        var value = path
        if value.hasPrefix("/") { value.removeFirst() }

        if value.hasPrefix("fsid-") {
            return String(value.dropFirst("fsid-".count))
        }
        if value.hasPrefix("pc-") {
            return String(value.dropFirst("pc-".count))
        }
        if value.isEmpty {
            return kind == .baidu ? "/" : String(rootPath.dropFirst())
        }
        return value
    }

    private func fileEntrySort(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
