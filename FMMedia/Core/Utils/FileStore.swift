import Foundation

/// 沙盒目录与通用文件工具
enum FileStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        ensure(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    static var caches: URL {
        ensure(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    /// 本机下载目录（可在「文件」App 中看到）
    static var downloads: URL {
        ensure(documents.appendingPathComponent("FM影媒下载", isDirectory: true))
    }

    static var subtitles: URL {
        ensure(caches.appendingPathComponent("Subtitles", isDirectory: true))
    }

    static var imageCache: URL {
        ensure(caches.appendingPathComponent("ImageCache", isDirectory: true))
    }

    static var appData: URL {
        ensure(support.appendingPathComponent("Data", isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }
}

/// 安全作用域书签（用于长期访问用户通过「文件」选择的目录）
enum BookmarkStore {
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .minimalBookmark,
                              includingResourceValuesForKeys: nil,
                              relativeTo: nil)
    }

    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}

/// 访问安全作用域资源，作用域在 block 结束后自动释放
enum ScopedAccess {
    static func withURL<T>(_ url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
