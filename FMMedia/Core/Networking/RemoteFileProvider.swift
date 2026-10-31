import Foundation

struct ProviderCapabilities: Hashable {
    var read: Bool = true
    var write: Bool = false
    var createFolder: Bool = false
    var delete: Bool = false
    var move: Bool = false
    var copy: Bool = false
    var rename: Bool = false
    var upload: Bool = false
    var download: Bool = true
    /// stream() 是否只是构造 URL（WebDAV / 本机）——扫描媒体库时可安全地取图片与 NFO
    var cheapStream: Bool = false

    static let readOnly = ProviderCapabilities()
    static let full = ProviderCapabilities(write: true, createFolder: true, delete: true,
                                           move: true, copy: true, rename: true, upload: true)
}

/// 统一远程/本机文件访问协议
protocol RemoteFileProvider: AnyObject {
    var config: MediaSourceConfig { get }
    var capabilities: ProviderCapabilities { get }
    /// 初始浏览路径
    var rootPath: String { get }

    func list(path: String) async throws -> [FileEntry]
    func stream(path: String) async throws -> StreamDescriptor

    func makeDirectory(path: String) async throws
    func remove(path: String) async throws
    func move(path: String, toDirectory: String) async throws
    func copy(path: String, toDirectory: String) async throws
    func rename(path: String, to newName: String) async throws
    func download(path: String, to destinationDirectory: URL, progress: @escaping (Double) -> Void) async throws -> URL
    func upload(localURL: URL, to directoryPath: String, progress: @escaping (Double) -> Void) async throws -> String
}

extension RemoteFileProvider {
    func makeDirectory(path: String) async throws {
        throw AppError.unsupported("\(config.kind.title) 不支持新建文件夹")
    }

    /// 读取远程文件内容（默认经 stream 地址 GET；NFO 解析等使用）
    func readFile(path: String) async throws -> Data {
        let descriptor = try await stream(path: path)
        let response = try await HTTPClient.request("GET", url: descriptor.url, headers: descriptor.headers, timeout: 60)
        return response.data
    }

    func remove(path: String) async throws {
        throw AppError.unsupported("\(config.kind.title) 不支持删除")
    }

    func move(path: String, toDirectory: String) async throws {
        throw AppError.unsupported("\(config.kind.title) 不支持移动")
    }

    func copy(path: String, toDirectory: String) async throws {
        throw AppError.unsupported("\(config.kind.title) 不支持复制")
    }

    func rename(path: String, to newName: String) async throws {
        throw AppError.unsupported("\(config.kind.title) 不支持重命名")
    }

    func download(path: String, to destinationDirectory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let descriptor = try await stream(path: path)
        let name = path.lastPathComponent.isEmpty ? "video" : path.lastPathComponent
        return try await HTTPFileTransfer.download(url: descriptor.url,
                                                   headers: descriptor.headers,
                                                   to: destinationDirectory,
                                                   preferredName: name,
                                                   progress: progress)
    }

    func upload(localURL: URL, to directoryPath: String, progress: @escaping (Double) -> Void) async throws -> String {
        throw AppError.unsupported("\(config.kind.title) 不支持上传")
    }
}

enum ProviderFactory {
    static func make(_ config: MediaSourceConfig) throws -> RemoteFileProvider {
        switch config.kind {
        case .local:
            return LocalFileProvider(config: config)
        case .webdav:
            return WebDAVProvider(config: config)
        case .emby, .jellyfin, .fnos, .zspace:
            return EmbyProvider(config: config)
        case .smb:
            return try SMBProvider.make(config: config)
        case .aliyun, .baidu, .pan115, .tianyi, .cmcc, .pan123, .guangya:
            return CloudDriveProvider(config: config)
        }
    }
}

// MARK: - 本机目录

final class LocalFileProvider: RemoteFileProvider {
    let config: MediaSourceConfig
    let capabilities: ProviderCapabilities = .full
    private let rootURL: URL
    private var scopeStarted = false

    init(config: MediaSourceConfig) {
        self.config = config
        let url: URL
        if let bookmark = config.localBookmark, let resolved = BookmarkStore.resolve(bookmark) {
            url = resolved.url
        } else if let path = config.localPath, !path.isEmpty {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            url = FileStore.documents
        }
        rootURL = url
        scopeStarted = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scopeStarted { rootURL.stopAccessingSecurityScopedResource() }
    }

    var rootPath: String { rootURL.path }

    private func url(for path: String) -> URL {
        if path.isEmpty || path == "/" { return rootURL }
        return URL(fileURLWithPath: path)
    }

    func list(path: String) async throws -> [FileEntry] {
        let directory = url(for: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])
        } catch {
            throw AppError.fileSystem("无法读取目录：\(describeError(error))")
        }

        return contents.compactMap { item -> FileEntry? in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = item.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            return FileEntry(name: name,
                             path: item.path,
                             isDirectory: isDirectory,
                             size: Int64(values?.fileSize ?? 0),
                             modified: values?.contentModificationDate)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func stream(path: String) async throws -> StreamDescriptor {
        let fileURL = url(for: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AppError.fileSystem("文件不存在")
        }
        return StreamDescriptor(url: fileURL, title: fileURL.lastPathComponent)
    }

    func makeDirectory(path: String) async throws {
        do {
            try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        } catch {
            throw AppError.fileSystem("新建文件夹失败：\(describeError(error))")
        }
    }

    func remove(path: String) async throws {
        do {
            try FileManager.default.removeItem(at: url(for: path))
        } catch {
            throw AppError.fileSystem("删除失败：\(describeError(error))")
        }
    }

    func move(path: String, toDirectory: String) async throws {
        let source = url(for: path)
        let targetDirectory = url(for: toDirectory)
        let target = FileStore.uniqueDestination(for: source.lastPathComponent, in: targetDirectory)
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw AppError.fileSystem("移动失败：\(describeError(error))")
        }
    }

    func copy(path: String, toDirectory: String) async throws {
        let source = url(for: path)
        let targetDirectory = url(for: toDirectory)
        let target = FileStore.uniqueDestination(for: source.lastPathComponent, in: targetDirectory)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: target)
            }.value
        } catch {
            throw AppError.fileSystem("复制失败：\(describeError(error))")
        }
    }

    func rename(path: String, to newName: String) async throws {
        let source = url(for: path)
        let target = source.deletingLastPathComponent().appendingPathComponent(newName.sanitizedFileName)
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw AppError.fileSystem("重命名失败：\(describeError(error))")
        }
    }

    func download(path: String, to destinationDirectory: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let source = url(for: path)
        let target = FileStore.uniqueDestination(for: source.lastPathComponent, in: destinationDirectory)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: source.path) {
                    if source.path != target.path {
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                } else {
                    throw AppError.fileSystem("文件不存在")
                }
            }.value
        } catch {
            throw AppError.fileSystem("复制失败：\(describeError(error))")
        }
        progress(1.0)
        return target
    }

    func upload(localURL: URL, to directoryPath: String, progress: @escaping (Double) -> Void) async throws -> String {
        let targetDirectory = url(for: directoryPath)
        let target = FileStore.uniqueDestination(for: localURL.lastPathComponent, in: targetDirectory)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: localURL, to: target)
            }.value
        } catch {
            throw AppError.fileSystem("写入失败：\(describeError(error))")
        }
        progress(1.0)
        return target.path
    }
}
