import Foundation

struct ScanSummary {
    var items: [MediaItem] = []
    var skippedFolders: [String] = []
    var scannedFolders: Int = 0
    var duration: TimeInterval = 0
}

/// 依据命名约定扫描本地目录，构建智能媒体库
///
/// 目录结构约定：
/// ```
/// ABC-123/                 ← 番号文件夹（可带 -u / -c / -uc）
///   ABC-123.mp4            ← 正片（名称同为番号）
///   ABC-123.srt            ← 字幕（名称同为番号）
///   ABC-123-poster.jpg     ← 小封面
///   ABC-123-fanart.jpg     ← 大封面
///   ABC-123.nfo            ← 影片信息
///   extrafanart/           ← 预览截图，文件名从 0 开始（0.jpg、1.jpg …）
/// ```
enum LibraryScanner {
    private struct FileMeta {
        var isDirectory: Bool = false
        var size: Int64 = 0
        var modified: Date? = nil
        var created: Date? = nil
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey
    ]

    static func scanLocal(source: MediaSourceConfig) -> ScanSummary {
        let started = Date()
        var summary = ScanSummary()
        guard let path = source.localPath, !path.isEmpty else { return summary }
        let root = URL(fileURLWithPath: path, isDirectory: true)

        ScopedAccess.withURL(root) { rootURL in
            let children = listing(rootURL)
            var directories: [URL] = []
            var files: [URL] = []

            for child in children {
                let meta = meta(of: child)
                if meta.isDirectory {
                    if child.lastPathComponent.lowercased() != "extrafanart" {
                        directories.append(child)
                    }
                } else {
                    files.append(child)
                }
            }

            for dir in directories {
                summary.scannedFolders += 1
                if let item = makeFolderItem(dir, source: source) {
                    summary.items.append(item)
                } else {
                    summary.skippedFolders.append(dir.lastPathComponent)
                }
            }

            summary.items.append(contentsOf: makeLooseItems(files, root: rootURL, source: source))
        }

        summary.items.sort { $0.addedAt > $1.addedAt }
        summary.duration = Date().timeIntervalSince(started)
        return summary
    }

    // MARK: - 单个番号文件夹

    private static func makeFolderItem(_ folder: URL, source: MediaSourceConfig) -> MediaItem? {
        let children = listing(folder)
        var files: [URL] = []
        var directories: [URL] = []
        for child in children {
            if meta(of: child).isDirectory {
                directories.append(child)
            } else {
                files.append(child)
            }
        }

        let folderName = folder.lastPathComponent
        let parsedCode = MediaCodeParser.parse(folderName)

        let videos = files.filter { MediaFileTypes.video.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return nil }

        let mainVideo = pickMainVideo(videos, code: parsedCode?.number)
        let code = parsedCode
            ?? MediaCodeParser.parse(mainVideo?.deletingPathExtension().lastPathComponent ?? folderName)
            ?? MediaCode(raw: folderName,
                         number: folderName,
                         isCracked: false,
                         hasSubtitleTag: false,
                         extraTokens: [])

        return composeItem(code: code,
                           isRecognized: parsedCode != nil,
                           folderName: folderName,
                           folderURL: folder,
                           itemID: folder.path,
                           files: files,
                           directories: directories,
                           mainVideo: mainVideo,
                           source: source)
    }

    // MARK: - 根目录散落文件

    private static func makeLooseItems(_ files: [URL], root: URL, source: MediaSourceConfig) -> [MediaItem] {
        var groups: [String: [URL]] = [:]
        var unrecognized: [URL] = []

        for file in files {
            if let code = MediaCodeParser.parse(file.lastPathComponent) {
                groups[code.number, default: []].append(file)
            } else if MediaFileTypes.video.contains(file.pathExtension.lowercased()) {
                unrecognized.append(file)
            }
        }

        var items: [MediaItem] = []

        for (number, groupFiles) in groups {
            let videos = groupFiles.filter { MediaFileTypes.video.contains($0.pathExtension.lowercased()) }
            guard let mainVideo = pickMainVideo(videos, code: number) else { continue }
            guard let code = MediaCodeParser.parse(mainVideo.deletingPathExtension().lastPathComponent)
                ?? MediaCodeParser.parse(number) else { continue }

            if let item = composeItem(code: code,
                                      isRecognized: true,
                                      folderName: code.number,
                                      folderURL: root,
                                      itemID: mainVideo.path,
                                      files: groupFiles,
                                      directories: [],
                                      mainVideo: mainVideo,
                                      source: source) {
                items.append(item)
            }
        }

        for video in unrecognized {
            let name = video.deletingPathExtension().lastPathComponent
            let code = MediaCode(raw: name, number: name, isCracked: false, hasSubtitleTag: false, extraTokens: [])
            if let item = composeItem(code: code,
                                      isRecognized: false,
                                      folderName: name,
                                      folderURL: root,
                                      itemID: video.path,
                                      files: [video],
                                      directories: [],
                                      mainVideo: video,
                                      source: source) {
                items.append(item)
            }
        }

        return items
    }

    // MARK: - 组装条目

    private static func composeItem(code: MediaCode,
                                    isRecognized: Bool,
                                    folderName: String,
                                    folderURL: URL,
                                    itemID: String,
                                    files: [URL],
                                    directories: [URL],
                                    mainVideo: URL?,
                                    source: MediaSourceConfig) -> MediaItem? {
        guard let mainVideo else { return nil }
        let videoMeta = meta(of: mainVideo)
        let codeKey = code.number.lowercased()
        let folderKey = folderName.lowercased()

        var item = MediaItem(id: itemID,
                             code: code.number,
                             rawName: folderName,
                             isCracked: code.isCracked,
                             hasSubtitleTag: code.hasSubtitleTag,
                             isRecognized: isRecognized,
                             folderPath: folderURL.path,
                             sourceID: source.id)

        item.video = MediaFileRef(path: mainVideo.path,
                                  name: mainVideo.lastPathComponent,
                                  size: videoMeta.size)

        // 字幕：优先与番号同名，其次与视频同名
        let videoBase = mainVideo.deletingPathExtension().lastPathComponent.lowercased()
        let subtitleFiles = files.filter { MediaFileTypes.subtitle.contains($0.pathExtension.lowercased()) }
        var selectedSubtitles = subtitleFiles.filter {
            let base = $0.deletingPathExtension().lastPathComponent.lowercased()
            if let parsed = MediaCodeParser.parse($0.lastPathComponent) {
                return parsed.number.lowercased() == codeKey
            }
            return base == videoBase || base.hasPrefix(codeKey) || base.hasPrefix(videoBase)
        }
        if selectedSubtitles.isEmpty && !subtitleFiles.isEmpty {
            selectedSubtitles = subtitleFiles
        }
        item.subtitles = selectedSubtitles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.map {
            MediaFileRef(path: $0.path, name: $0.lastPathComponent, size: meta(of: $0).size)
        }
        item.nfoPath = pickNFO(files, codeKey: codeKey, folderKey: folderKey)?.path

        // 封面
        item.poster = findArtwork(files,
                                  codeKey: codeKey,
                                  folderKey: folderKey,
                                  suffixes: ["-poster", "-cover", "-thumb"],
                                  fallbackNames: ["poster", "folder", "cover"]).map { ImageRef(fileURL: $0) }

        item.fanart = findArtwork(files,
                                  codeKey: codeKey,
                                  folderKey: folderKey,
                                  suffixes: ["-fanart", "-backdrop", "-background"],
                                  fallbackNames: ["fanart", "backdrop", "background", "banner"]).map { ImageRef(fileURL: $0) }

        // extrafanart 预览截图
        if let extraDir = directories.first(where: { $0.lastPathComponent.lowercased() == "extrafanart" }) {
            let images = listing(extraDir)
                .filter { MediaFileTypes.image.contains($0.pathExtension.lowercased()) }
                .sorted(by: previewSort)
            item.previews = images.map { ImageRef(fileURL: $0) }
        }

        // NFO 信息
        if let nfoPath = item.nfoPath, let nfo = NFOParser.parse(url: URL(fileURLWithPath: nfoPath)) {
            item.title = nfo.title.isEmpty ? nfo.originalTitle : nfo.title
            item.originalTitle = nfo.originalTitle.isEmpty ? nil : nfo.originalTitle
            item.plot = nfo.plot.isEmpty ? nfo.outline : nfo.plot
            item.studio = nfo.studio
            item.publisher = nfo.publisher
            item.year = nfo.year
            item.releaseDate = nfo.premiered
            item.runtimeMinutes = nfo.runtimeMinutes
            item.rating = nfo.rating
            item.genres = nfo.genres
            item.tags = nfo.tags
            item.actors = nfo.actors.map { MediaActor(name: $0.name, role: $0.role) }
            if item.poster == nil, let poster = nfo.posterURL, !poster.isEmpty {
                item.poster = imageRef(for: poster, folderURL: folderURL)
            }
            if item.fanart == nil, let fanart = nfo.fanartURL, !fanart.isEmpty {
                item.fanart = imageRef(for: fanart, folderURL: folderURL)
            }
        }

        if item.title.isEmpty { item.title = code.displayName }
        item.durationSeconds = item.runtimeMinutes.map { Double($0) * 60 }
        item.addedAt = videoMeta.created ?? videoMeta.modified ?? Date()
        item.modifiedAt = meta(of: folderURL).modified
        return item
    }

    // MARK: - 工具

    private static func pickMainVideo(_ videos: [URL], code: String?) -> URL? {
        guard !videos.isEmpty else { return nil }
        if let code {
            let exact = videos.filter {
                MediaCodeParser.parse($0.lastPathComponent)?.number.caseInsensitiveCompare(code) == .orderedSame
            }
            if let best = exact.max(by: { meta(of: $0).size < meta(of: $1).size }) {
                return best
            }
        }
        return videos.max(by: { meta(of: $0).size < meta(of: $1).size })
    }

    private static func pickNFO(_ files: [URL], codeKey: String, folderKey: String) -> URL? {
        let nfos = files.filter { $0.pathExtension.lowercased() == "nfo" }
        guard !nfos.isEmpty else { return nil }
        if let exact = nfos.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == codeKey
        }) { return exact }
        if let movie = nfos.first(where: {
            let base = $0.deletingPathExtension().lastPathComponent.lowercased()
            return base == "movie" || base == folderKey
        }) { return movie }
        return nfos.first
    }

    private static func findArtwork(_ files: [URL],
                                    codeKey: String,
                                    folderKey: String,
                                    suffixes: [String],
                                    fallbackNames: [String]) -> URL? {
        let images = files.filter { MediaFileTypes.image.contains($0.pathExtension.lowercased()) }
        for suffix in suffixes {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == codeKey + suffix
            }) { return match }
        }
        for suffix in suffixes {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == folderKey + suffix
            }) { return match }
        }
        for name in fallbackNames {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
            }) { return match }
        }
        return nil
    }

    private static func imageRef(for raw: String, folderURL: URL) -> ImageRef? {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { return nil }
            return ImageRef(url: url)
        }
        let fileURL = folderURL.appendingPathComponent(trimmed)
        return FileManager.default.fileExists(atPath: fileURL.path) ? ImageRef(fileURL: fileURL) : nil
    }

    private static func previewSort(_ a: URL, _ b: URL) -> Bool {
        let nameA = a.deletingPathExtension().lastPathComponent
        let nameB = b.deletingPathExtension().lastPathComponent
        let numA = Int(nameA) ?? Int.max
        let numB = Int(nameB) ?? Int.max
        if numA != numB { return numA < numB }
        return nameA.localizedStandardCompare(nameB) == .orderedAscending
    }

    private static func listing(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url,
                                                      includingPropertiesForKeys: resourceKeys,
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        return items
    }

    private static func meta(of url: URL) -> FileMeta {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return FileMeta() }
        return FileMeta(isDirectory: values.isDirectory ?? false,
                        size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate,
                        created: values.creationDate)
    }
}

/// 长时间持有本机目录的安全作用域访问权限
@MainActor
final class LocalAccessManager {
    static let shared = LocalAccessManager()

    private var activeURLs: [UUID: URL] = [:]

    private init() {}

    func activate(_ source: MediaSourceConfig) {
        guard source.kind == .local else { return }
        if activeURLs[source.id] != nil { return }
        let url: URL?
        if let bookmark = source.localBookmark, let resolved = BookmarkStore.resolve(bookmark) {
            url = resolved.url
        } else if let path = source.localPath {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url else { return }
        _ = url.startAccessingSecurityScopedResource()
        activeURLs[source.id] = url
        Log.info("本机目录已授权: \(url.lastPathComponent)")
    }

    func deactivate(_ sourceID: UUID) {
        if let url = activeURLs.removeValue(forKey: sourceID) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func activateAll(_ sources: [MediaSourceConfig]) {
        for source in sources where source.kind == .local {
            activate(source)
        }
    }
}
