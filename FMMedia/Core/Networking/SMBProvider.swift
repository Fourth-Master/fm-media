import Foundation

/// SMB 支持
///
/// 由于 iOS 没有内置 SMB 客户端，这里以可选依赖 AMSMB2 实现：
/// 在 Xcode 中 `File > Add Package Dependencies` 添加
/// `https://github.com/amosavian/AMSMB2`（3.x / 4.x）后，本文件自动生效。
/// 未添加依赖时，SMB 来源会给出明确提示，其他功能不受影响。
enum SMBProvider {
    static func make(config: MediaSourceConfig) throws -> RemoteFileProvider {
        #if canImport(AMSMB2)
        return SMBLibProvider(config: config)
        #else
        throw AppError.unsupported("当前构建未包含 SMB 组件。请添加 AMSMB2 依赖后重新编译，或改用 WebDAV 连接同一共享目录。")
        #endif
    }
}

#if canImport(AMSMB2)
import AMSMB2

final class SMBLibProvider: RemoteFileProvider {
    let config: MediaSourceConfig
    let capabilities: ProviderCapabilities = .full

    private let shareURL: URL
    private let sharePath: String
    private let host: String

    init(config: MediaSourceConfig) {
        self.config = config
        let raw = HTTPClient.normalizeServerAddress(config.baseURL, defaultScheme: "smb")
        let cleaned = raw.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let share = config.extra["share"] ?? ""
        let basePath = config.extra["path"] ?? ""
        self.host = cleaned
        self.sharePath = basePath.isEmpty ? "/" : (basePath.hasPrefix("/") ? basePath : "/" + basePath)
        self.shareURL = URL(string: "smb://\(cleaned)/\(share)") ?? URL(string: "smb://\(cleaned)")!
    }

    var rootPath: String { sharePath }

    private func makeClient() -> AMSMB2 {
        let user = config.username
        let credential = AMSMB2Credential(username: user, password: config.secret)
        let domain = config.extra["domain"] ?? ""
        return AMSMB2(url: shareURL, credential: credential, domain: domain)
    }

    private func withClient<T>(_ body: (AMSMB2) async throws -> T) async throws -> T {
        let client = makeClient()
        try await client.connectShare()
        defer {
            client.disconnectShare(gracefully: true)
        }
        return try await body(client)
    }

    private func fullPath(_ path: String) -> String {
        if path.isEmpty || path == "/" { return sharePath }
        return path.hasPrefix("/") ? path : "/" + path
    }

    func list(path: String) async throws -> [FileEntry] {
        let target = fullPath(path)
        return try await withClient { client in
            let items = try await client.contentsOfDirectory(atPath: target)
            return items.compactMap { item -> FileEntry? in
                let name = (item[.nameKey] as? String) ?? ""
                guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
                let isDirectory = (item[.isDirectoryKey] as? Bool) ?? false
                let size = (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                let modified = item[.contentModificationDateKey] as? Date
                let itemPath = target == "/" ? "/\(name)" : "\(target)/\(name)"
                return FileEntry(name: name,
                                 path: itemPath,
                                 isDirectory: isDirectory,
                                 size: size,
                                 modified: modified)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// SMB 无法直接给出可播放 URL：先缓存到本机再播放
    func stream(path: String) async throws -> StreamDescriptor {
        let name = (path as NSString).lastPathComponent
        let cacheDirectory = FileStore.caches.appendingPathComponent("SMBStream", isDirectory: true)
        FileStore.ensure(cacheDirectory)
        let destination = cacheDirectory.appendingPathComponent(name.sanitizedFileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return StreamDescriptor(url: destination, title: name)
        }
        let target = fullPath(path)
        try await withClient { client in
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try await client.downloadItem(atPath: target, to: destination, progress: nil)
        }
        return StreamDescriptor(url: destination, title: name)
    }

    func makeDirectory(path: String) async throws {
        let target = fullPath(path)
        try await withClient { client in
            try await client.createDirectory(atPath: target)
        }
    }

    func remove(path: String) async throws {
        let target = fullPath(path)
        try await withClient { client in
            try await client.removeItem(atPath: target)
        }
    }

    func move(path: String, toDirectory: String) async throws {
        let source = fullPath(path)
        let name = (path as NSString).lastPathComponent
        let target = fullPath(toDirectory).hasSuffix("/")
            ? fullPath(toDirectory) + name
            : fullPath(toDirectory) + "/" + name
        try await withClient { client in
            try await client.moveItem(atPath: source, toPath: target)
        }
    }

    func rename(path: String, to newName: String) async throws {
        let source = fullPath(path)
        let directory = (source as NSString).deletingLastPathComponent
        let target = directory.hasSuffix("/") ? directory + newName : directory + "/" + newName
        try await withClient { client in
            try await client.moveItem(atPath: source, toPath: target)
        }
    }

    func download(path: String, to destinationDirectory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let name = (path as NSString).lastPathComponent
        let target = FileStore.uniqueDestination(for: name.sanitizedFileName, in: destinationDirectory)
        let remote = fullPath(path)
        try await withClient { client in
            try await client.downloadItem(atPath: remote, to: target, progress: { received, total in
                guard total > 0 else { return }
                progress(min(1.0, Double(received) / Double(total)))
            })
        }
        progress(1.0)
        return target
    }

    func upload(localURL: URL, to directoryPath: String, progress: @escaping (Double) -> Void) async throws -> String {
        let directory = fullPath(directoryPath)
        let target = directory.hasSuffix("/")
            ? directory + localURL.lastPathComponent
            : directory + "/" + localURL.lastPathComponent
        try await withClient { client in
            try await client.uploadItem(at: localURL, toPath: target, progress: { sent, total in
                guard total > 0 else { return }
                progress(min(1.0, Double(sent) / Double(total)))
            })
        }
        progress(1.0)
        return target
    }
}
#endif
