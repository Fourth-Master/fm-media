import Foundation

/// Emby / Jellyfin / 飞牛影视 / 极空间影视（兼容模式）
final class EmbyProvider: RemoteFileProvider {
    let config: MediaSourceConfig

    var capabilities: ProviderCapabilities {
        var caps = ProviderCapabilities.readOnly
        caps.delete = true
        return caps
    }

    private let base: String
    private let token: String
    private let userId: String

    init(config: MediaSourceConfig) {
        self.config = config
        self.base = HTTPClient.normalizeServerAddress(config.baseURL)
        self.token = config.secret
        self.userId = config.extra["userId"] ?? ""
    }

    var rootPath: String { "/" }

    private var authHeader: String {
        let deviceId = config.extra["deviceId"] ?? "FM-iOS"
        return "MediaBrowser Client=\"FM影媒\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\", Token=\"\(token)\""
    }

    private var extraHeaders: [String: String] {
        ["X-Emby-Authorization": authHeader, "Accept": "application/json"]
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        HTTPClient.url(base: base, path: path, query: query)
    }

    private func itemId(from path: String) -> String? {
        let trimmed = path.hasPrefix("/item/") ? String(path.dropFirst("/item/".count)) : path
        let clean = trimmed.split(separator: "?").first.map(String.init) ?? trimmed
        return clean.isEmpty ? nil : clean.removingPercentEncoding ?? clean
    }

    func list(path: String) async throws -> [FileEntry] {
        if path.isEmpty || path == "/" {
            return try await listViews()
        }
        guard let id = itemId(from: path), let url = url("/Users/\(userId)/Items", query: [
            URLQueryItem(name: "ParentId", value: id),
            URLQueryItem(name: "Recursive", value: "false"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Path,RunTimeTicks"),
            URLQueryItem(name: "Limit", value: "500")
        ]) else {
            throw AppError.notConfigured("服务器参数不完整，请重新登录该媒体服务器")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: extraHeaders)
        let decoded = try decodeItems(response.data)

        return decoded.compactMap { item -> FileEntry? in
            guard let name = item.Name, !name.isEmpty else { return nil }
            let isFolder = item.IsFolder ?? (item.itemType == "Folder" || item.itemType == "CollectionFolder" || item.itemType == "Series" || item.itemType == "BoxSet")
            return FileEntry(name: name,
                             path: "/item/\(item.Id)",
                             isDirectory: isFolder,
                             size: item.MediaSources?.first?.Size ?? 0,
                             kind: isFolder ? .folder : .video)
        }
    }

    private func listViews() async throws -> [FileEntry] {
        guard let url = url("/Users/\(userId)/Views") else {
            throw AppError.notConfigured("服务器地址无效")
        }
        let response = try await HTTPClient.request("GET", url: url, headers: extraHeaders)
        let decoded = try decodeItems(response.data)
        return decoded.map {
            FileEntry(name: $0.Name ?? "媒体库", path: "/item/\($0.Id)", isDirectory: true, size: 0, kind: .folder)
        }
    }

    func stream(path: String) async throws -> StreamDescriptor {
        guard let id = itemId(from: path) else {
            throw AppError.notConfigured("无法识别的媒体条目")
        }
        guard let url = url("/Videos/\(id)/stream", query: [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "MediaSourceId", value: id)
        ]) else {
            throw AppError.notConfigured("服务器地址无效")
        }
        return StreamDescriptor(url: url, headers: extraHeaders, title: path.lastPathComponent)
    }

    /// 删除服务器上的媒体（Emby 会连同文件一起删除，需要账号具备删除权限）
    func remove(path: String) async throws {
        guard userId.isEmpty == false else {
            throw AppError.notConfigured("缺少登录信息，请重新登录该媒体服务器")
        }
        guard let id = itemId(from: path) else {
            throw AppError.notConfigured("无法识别的媒体条目")
        }
        guard let url = url("/Items/\(id)") else {
            throw AppError.notConfigured("服务器地址无效")
        }
        _ = try await HTTPClient.request("DELETE",
                                         url: url,
                                         headers: extraHeaders,
                                         extraAcceptedStatus: [204, 404])
    }

    private func decodeItems(_ data: Data) throws -> [EmbyItem] {
        do {
            let decoded = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
            return decoded.Items ?? []
        } catch {
            if let json = JSONValue.parse(data), let items = JSONValue.dict(json)["Items"] {
                return JSONValue.dictArray(items).compactMap { EmbyItem.from($0) }
            }
            throw AppError.network("无法解析媒体服务器返回的数据")
        }
    }

    // MARK: - 媒体库导入

    /// 递归拉取影片，用于「智能媒体库」直接导入
    func fetchLibraryItems(limit: Int = 3000) async throws -> [MediaItem] {
        let baseQuery: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Video"),
            URLQueryItem(name: "Fields", value: "Overview,Genres,CommunityRating,ProductionYear,RunTimeTicks,Path,MediaSources,PremiereDate"),
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: String(min(limit, 300))),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop")
        ]

        var collected: [EmbyItem] = []
        var startIndex = 0
        while startIndex < limit {
            guard let pageURL = url("/Users/\(userId)/Items", query: baseQuery + [
                URLQueryItem(name: "StartIndex", value: String(startIndex))
            ]) else {
                throw AppError.notConfigured("服务器地址无效")
            }
            let response = try await HTTPClient.request("GET", url: pageURL, headers: extraHeaders)
            let decoded = try decodeItems(response.data)
            if decoded.isEmpty { break }
            collected.append(contentsOf: decoded)
            if decoded.count < 200 { break }
            startIndex += decoded.count
        }

        var items: [MediaItem] = []
        for entry in collected {
            guard let name = entry.Name, !name.isEmpty else { continue }
            let parsed = MediaCodeParser.find(in: name)
                ?? entry.Path.flatMap { MediaCodeParser.find(in: $0) }
            let codeString = parsed?.number ?? name

            var item = MediaItem(id: "\(config.id.uuidString)-emby-\(entry.Id)",
                                 code: codeString,
                                 rawName: name,
                                 isCracked: parsed?.isCracked ?? false,
                                 hasSubtitleTag: parsed?.hasSubtitleTag ?? false,
                                 isRecognized: parsed != nil,
                                 title: name,
                                 originalTitle: entry.OriginalTitle,
                                 plot: entry.Overview ?? "",
                                 year: entry.ProductionYear,
                                 releaseDate: entry.PremiereDate ?? "",
                                 runtimeMinutes: entry.RunTimeTicks.map { Int($0 / 600_000_000) },
                                 rating: entry.CommunityRating,
                                 genres: entry.Genres ?? [],
                                 video: MediaFileRef(path: "/item/\(entry.Id)",
                                                     name: entry.MediaSources?.first?.Container.map { "\(name).\($0)" } ?? name,
                                                     size: entry.MediaSources?.first?.Size ?? 0),
                                 folderPath: "/item/\(entry.Id)",
                                 sourceID: config.id)

            item.remoteStream = try? await stream(path: "/item/\(entry.Id)")
            item.durationSeconds = entry.RunTimeTicks.map { Double($0) / 10_000_000 }

            if let posterURL = url("/Items/\(entry.Id)/Images/Primary", query: [
                URLQueryItem(name: "maxWidth", value: "600"),
                URLQueryItem(name: "quality", value: "88"),
                URLQueryItem(name: "api_key", value: token)
            ]) {
                item.poster = ImageRef(url: posterURL)
            }
            if let fanartURL = url("/Items/\(entry.Id)/Images/Backdrop/0", query: [
                URLQueryItem(name: "maxWidth", value: "1600"),
                URLQueryItem(name: "quality", value: "88"),
                URLQueryItem(name: "api_key", value: token)
            ]) {
                item.fanart = ImageRef(url: fanartURL)
            }
            if let path = entry.Path {
                item.tags.append(path.lastPathComponent)
            }
            items.append(item)
        }
        return items
    }

    // MARK: - 登录

    struct AuthResult {
        var accessToken: String
        var userId: String
        var serverName: String
        var deviceId: String
    }

    static func authenticate(baseURL: String,
                             username: String,
                             password: String) async throws -> AuthResult {
        let base = HTTPClient.normalizeServerAddress(baseURL)
        guard let url = HTTPClient.url(base: base, path: "/Users/AuthenticateByName") else {
            throw AppError.notConfigured("服务器地址无效")
        }
        let deviceId = "FM-" + UUID().uuidString.prefix(8)
        let header = "MediaBrowser Client=\"FM影媒\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
        let body = try HTTPClient.jsonBody(["Username": username, "Pw": password])

        let response = try await HTTPClient.request("POST",
                                                    url: url,
                                                    headers: [
                                                        "X-Emby-Authorization": header,
                                                        "Content-Type": "application/json",
                                                        "Accept": "application/json"
                                                    ],
                                                    body: body)
        guard let json = JSONValue.parse(response.data) else {
            throw AppError.network("登录响应无法解析")
        }
        let dict = JSONValue.dict(json)
        let user = JSONValue.dict(dict["User"])
        guard let token = JSONValue.string(dict["AccessToken"]),
              let userId = JSONValue.string(user["Id"]) else {
            throw AppError.auth("账号或密码错误")
        }

        var serverName = ""
        if let infoURL = HTTPClient.url(base: base, path: "/System/Info/Public") {
            if let info = try? await HTTPClient.request("GET", url: infoURL, headers: ["Accept": "application/json"]),
               let json = JSONValue.parse(info.data) {
                serverName = JSONValue.string(JSONValue.dict(json)["ServerName"]) ?? ""
            }
        }

        return AuthResult(accessToken: token, userId: userId, serverName: serverName, deviceId: deviceId)
    }
}

// MARK: - DTO

struct EmbyItem: Decodable {
    let Id: String
    let Name: String?
    let OriginalTitle: String?
    let itemType: String?
    let IsFolder: Bool?
    let Path: String?
    let Overview: String?
    let ProductionYear: Int?
    let CommunityRating: Double?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let PremiereDate: String?
    let MediaSources: [EmbyMediaSource]?

    enum CodingKeys: String, CodingKey {
        case Id
        case Name
        case OriginalTitle
        case itemType = "Type"
        case IsFolder
        case Path
        case Overview
        case ProductionYear
        case CommunityRating
        case RunTimeTicks
        case Genres
        case PremiereDate
        case MediaSources
    }

    static func from(_ dict: [String: Any]) -> EmbyItem? {
        guard let id = JSONValue.string(dict["Id"]) else { return nil }
        return EmbyItem(Id: id,
                        Name: JSONValue.string(dict["Name"]),
                        OriginalTitle: JSONValue.string(dict["OriginalTitle"]),
                        itemType: JSONValue.string(dict["Type"]),
                        IsFolder: JSONValue.bool(dict["IsFolder"]),
                        Path: JSONValue.string(dict["Path"]),
                        Overview: JSONValue.string(dict["Overview"]),
                        ProductionYear: JSONValue.int(dict["ProductionYear"]),
                        CommunityRating: JSONValue.double(dict["CommunityRating"]),
                        RunTimeTicks: JSONValue.int64(dict["RunTimeTicks"]),
                        Genres: (dict["Genres"] as? [String]),
                        PremiereDate: JSONValue.string(dict["PremiereDate"]),
                        MediaSources: JSONValue.dictArray(dict["MediaSources"]).compactMap { EmbyMediaSource.from($0) })
    }
}

struct EmbyMediaSource: Decodable {
    let Size: Int64?
    let Container: String?

    static func from(_ dict: [String: Any]) -> EmbyMediaSource? {
        EmbyMediaSource(Size: JSONValue.int64(dict["Size"]), Container: JSONValue.string(dict["Container"]))
    }
}

struct EmbyItemsResponse: Decodable {
    let Items: [EmbyItem]?
    let TotalRecordCount: Int?
}
