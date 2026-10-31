import Foundation

/// 扫描远程来源（WebDAV / SMB），命名规则与本机目录一致：
/// 番号文件夹 / 同名视频与字幕 / poster / fanart / nfo / extrafanart
enum RemoteLibraryScanner {
    private final class State {
        var dirs = 0
        var videos = 0
        let maxDirs: Int
        let maxVideos: Int

        init(maxDirs: Int, maxVideos: Int) {
            self.maxDirs = maxDirs
            self.maxVideos = maxVideos
        }
    }

    /// 根目录一级签名：条目名称 + 数量 + 大小/修改时间（单次列目录请求）
    static func topLevelSignature(source: MediaSourceConfig) async -> String? {
        guard let provider = try? await ProviderFactory.make(source) else { return nil }
        guard let entries = try? await provider.list(path: provider.rootPath) else { return nil }
        let parts = entries.map { entry -> String in
            var line = entry.name + (entry.isDirectory ? "/d" : "/f")
            if !entry.isDirectory { line += "/\(entry.size)" }
            if let modified = entry.modified { line += "/\(Int(modified.timeIntervalSince1970))" }
            return line
        }
        return "\(entries.count)-\(ScanFingerprint.hash(parts))"
    }

    static func scan(source: MediaSourceConfig,
                     knownFolderPaths: Set<String>? = nil,
                     progress: @escaping (String) -> Void) async -> [MediaItem] {
        guard let provider = try? await ProviderFactory.make(source) else {
            Log.error("远程扫描失败：无法创建来源 \(source.name)")
            return []
        }
        // cheapStream = stream() 只是拼 URL（WebDAV）：可以放心取图片/NFO；
        // 云盘 / SMB 的 stream() 有真实代价，扫描时跳过这些附加请求
        let cheap = provider.capabilities.cheapStream
        let state = State(maxDirs: 600, maxVideos: 3000)
        var items: [MediaItem] = []

        func report() {
            let text = "\(source.name)：已扫描 \(state.dirs) 个目录，找到 \(state.videos) 个视频"
            Task { @MainActor in progress(text) }
        }

        func walk(_ path: String, depth: Int) async {
            if let known = knownFolderPaths, known.contains(path) { return }
            guard depth <= 4, state.dirs < state.maxDirs, state.videos < state.maxVideos else { return }
            state.dirs += 1
            report()

            let entries: [FileEntry]
            do {
                entries = try await provider.list(path: path)
            } catch {
                Log.error("远程扫描：列目录失败 \(path)", error)
                return
            }

            let videos = entries.filter { !$0.isDirectory && $0.kind == .video }
            let subdirs = entries.filter { $0.isDirectory && $0.name.lowercased() != "extrafanart" }

            if let main = pickMainVideo(videos) {
                state.videos += videos.count
                report()
                let folderParsed = MediaCodeParser.parse(path.lastPathComponent)
                let parsed = folderParsed
                    ?? MediaCodeParser.parse(main.name)
                    ?? MediaCode(raw: path.lastPathComponent, number: path.lastPathComponent,
                                 isCracked: false, hasSubtitleTag: false, extraTokens: [])
                if let item = await composeItem(code: parsed,
                                                recognized: folderParsed != nil,
                                                dirPath: path,
                                                dirName: path.lastPathComponent,
                                                entries: entries,
                                                subdirs: subdirs,
                                                mainVideo: main,
                                                source: source,
                                                provider: provider,
                                                cheap: cheap) {
                    items.append(item)
                }
            }

            if depth < 4 {
                for sub in subdirs {
                    await walk(sub.path, depth: depth + 1)
                }
            }
        }

        let root = provider.rootPath
        let rootEntries = (try? await provider.list(path: root)) ?? []
        if rootEntries.isEmpty && root != "/" {
            Log.error("远程扫描：起始目录为空或不可访问 \(root)")
        }

        // 1) 根目录散落文件按番号聚合
        let rootFiles = rootEntries.filter { !$0.isDirectory }
        items.append(contentsOf: await looseItems(rootFiles,
                                                  rootPath: root,
                                                  source: source,
                                                  provider: provider,
                                                  cheap: cheap,
                                                  state: state,
                                                  report: report))

        // 2) 番号文件夹逐层扫描
        let rootDirs = rootEntries.filter { $0.isDirectory && $0.name.lowercased() != "extrafanart" }
        for dir in rootDirs {
            await walk(dir.path, depth: 2)
        }

        items.sort { $0.addedAt > $1.addedAt }
        Log.info("远程扫描完成 \(source.name)：\(items.count) 部影片，遍历 \(state.dirs) 个目录")
        return items
    }

    // MARK: - 根目录散落文件

    private static func looseItems(_ files: [FileEntry],
                                   rootPath: String,
                                   source: MediaSourceConfig,
                                   provider: RemoteFileProvider,
                                   cheap: Bool,
                                   state: State,
                                   report: @escaping () -> Void) async -> [MediaItem] {
        var groups: [String: [FileEntry]] = [:]
        var unmatched: [FileEntry] = []
        for file in files {
            if let code = MediaCodeParser.parse(file.name) {
                groups[code.number, default: []].append(file)
            } else if file.kind == .video {
                unmatched.append(file)
            }
        }

        var items: [MediaItem] = []
        for (number, group) in groups {
            let videos = group.filter { $0.kind == .video }
            guard let main = pickMainVideo(videos),
                  let code = MediaCodeParser.parse(main.name) ?? MediaCodeParser.parse(number) else { continue }
            state.videos += videos.count
            report()
            if let item = await composeItem(code: code,
                                            recognized: true,
                                            dirPath: rootPath,
                                            dirName: code.number,
                                            entries: group,
                                            subdirs: [],
                                            mainVideo: main,
                                            source: source,
                                            provider: provider,
                                            cheap: cheap) {
                items.append(item)
            }
        }

        for file in unmatched {
            let name = (file.name as NSString).deletingPathExtension
            let code = MediaCode(raw: name, number: name, isCracked: false, hasSubtitleTag: false, extraTokens: [])
            state.videos += 1
            report()
            if let item = await composeItem(code: code,
                                            recognized: false,
                                            dirPath: rootPath,
                                            dirName: name,
                                            entries: [file],
                                            subdirs: [],
                                            mainVideo: file,
                                            source: source,
                                            provider: provider,
                                            cheap: cheap) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - 组装条目

    private static func composeItem(code: MediaCode,
                                    recognized: Bool,
                                    dirPath: String,
                                    dirName: String,
                                    entries: [FileEntry],
                                    subdirs: [FileEntry],
                                    mainVideo: FileEntry,
                                    source: MediaSourceConfig,
                                    provider: RemoteFileProvider,
                                    cheap: Bool) async -> MediaItem? {
        let codeKey = code.number.lowercased()
        let folderKey = dirName.lowercased()

        var item = MediaItem(id: "\(source.id.uuidString)-r-\(mainVideo.path)",
                             code: code.number,
                             rawName: dirName,
                             isCracked: code.isCracked,
                             hasSubtitleTag: code.hasSubtitleTag,
                             isRecognized: recognized,
                             folderPath: dirPath,
                             sourceID: source.id)

        item.video = MediaFileRef(path: mainVideo.path, name: mainVideo.name, size: mainVideo.size)

        guard let stream = try? await provider.stream(path: mainVideo.path) else {
            Log.error("远程扫描：无法获取播放地址 \(mainVideo.path)")
            return nil
        }
        item.remoteStream = stream

        // 字幕：番号同名优先
        let videoBase = ((mainVideo.name as NSString).deletingPathExtension).lowercased()
        var subs = entries.filter { $0.kind == .subtitle && matchesSubtitle($0.name, codeKey: codeKey, videoBase: videoBase) }
        if subs.isEmpty {
            subs = entries.filter { $0.kind == .subtitle }
        }
        item.subtitles = subs.map { MediaFileRef(path: $0.path, name: $0.name, size: $0.size) }
        if cheap {
            for sub in subs.prefix(5) {
                if let descriptor = try? await provider.stream(path: sub.path) {
                    item.remoteSubtitleStreams.append(descriptor)
                }
            }
        }

        item.nfoPath = pickNFO(entries, codeKey: codeKey, folderKey: folderKey)?.path

        if cheap {
            let images = entries.filter { $0.kind == .image }
            if let poster = findImage(images,
                                      codeKey: codeKey,
                                      folderKey: folderKey,
                                      suffixes: ["-poster", "-cover", "-thumb"],
                                      fallbackNames: ["poster", "folder", "cover"]) {
                item.poster = await imageRef(poster, provider: provider)
            }
            if let fanart = findImage(images,
                                      codeKey: codeKey,
                                      folderKey: folderKey,
                                      suffixes: ["-fanart", "-backdrop", "-background"],
                                      fallbackNames: ["fanart", "backdrop", "background", "banner"]) {
                item.fanart = await imageRef(fanart, provider: provider)
            }

            if let extraDir = subdirs.first(where: { $0.name.lowercased() == "extrafanart" }) {
                if let previewEntries = try? await provider.list(path: extraDir.path) {
                    let previews = previewEntries
                        .filter { $0.kind == .image }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        .prefix(12)
                    for preview in previews {
                        if let ref = await imageRef(preview, provider: provider) {
                            item.previews.append(ref)
                        }
                    }
                }
            }

            if let nfoPath = item.nfoPath, let data = try? await provider.readFile(path: nfoPath),
               let nfo = NFOParser.parse(data: data) {
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
                item.durationSeconds = item.runtimeMinutes.map { Double($0) * 60 }
            }
        }

        if item.title.isEmpty { item.title = code.displayName }
        item.addedAt = mainVideo.modified ?? Date()
        return item
    }

    // MARK: - 工具

    private static func pickMainVideo(_ videos: [FileEntry]) -> FileEntry? {
        videos.max { $0.size < $1.size }
    }

    private static func matchesSubtitle(_ name: String, codeKey: String, videoBase: String) -> Bool {
        if let parsed = MediaCodeParser.parse(name) {
            return parsed.number.lowercased() == codeKey
        }
        let base = ((name as NSString).deletingPathExtension).lowercased()
        return base == videoBase || base.hasPrefix(codeKey) || base.hasPrefix(videoBase)
    }

    private static func pickNFO(_ entries: [FileEntry], codeKey: String, folderKey: String) -> FileEntry? {
        let nfos = entries.filter { $0.kind == .nfo }
        guard !nfos.isEmpty else { return nil }
        if let exact = nfos.first(where: {
            (($0.name as NSString).deletingPathExtension).lowercased() == codeKey
        }) { return exact }
        if let movie = nfos.first(where: {
            let base = (($0.name as NSString).deletingPathExtension).lowercased()
            return base == "movie" || base == folderKey
        }) { return movie }
        return nfos.first
    }

    private static func findImage(_ images: [FileEntry],
                                  codeKey: String,
                                  folderKey: String,
                                  suffixes: [String],
                                  fallbackNames: [String]) -> FileEntry? {
        for suffix in suffixes {
            if let match = images.first(where: {
                (($0.name as NSString).deletingPathExtension).lowercased() == codeKey + suffix
            }) { return match }
        }
        for suffix in suffixes {
            if let match = images.first(where: {
                (($0.name as NSString).deletingPathExtension).lowercased() == folderKey + suffix
            }) { return match }
        }
        for name in fallbackNames {
            if let match = images.first(where: {
                (($0.name as NSString).deletingPathExtension).lowercased() == name
            }) { return match }
        }
        return nil
    }

    private static func imageRef(_ entry: FileEntry, provider: RemoteFileProvider) async -> ImageRef? {
        guard let descriptor = try? await provider.stream(path: entry.path) else { return nil }
        return ImageRef(url: descriptor.url, headers: descriptor.headers)
    }
}
