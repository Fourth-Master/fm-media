import Foundation

/// 重复番号检测与清理
enum DuplicateFinder {
    struct Candidate: Identifiable, Hashable {
        var id: String { item.id }
        var item: MediaItem
        var score: Int          // 越小越应被清理（0 = 最优先清理）
        var reasons: [String]
    }

    struct Group: Identifiable {
        var id: String { code }
        var code: String
        var keep: Candidate
        var duplicates: [Candidate]
    }

    struct Report {
        var groups: [Group] = []
        var totalDuplicates: Int = 0
    }

    // MARK: - 检测

    /// 在媒体库中找重复番号。显示名差异（如翻译名）不影响判定；完全相同的 id 视为同一条目。
    static func analyze(items: [MediaItem]) -> Report {
        var byCode: [String: [MediaItem]] = [:]
        for item in items where item.isRecognized {
            byCode[item.code.uppercased(), default: []].append(item)
        }

        var groups: [Group] = []
        var total = 0

        for (code, entries) in byCode.sorted(by: { $0.key < $1.key }) {
            guard entries.count > 1 else { continue }
            let ranked = entries
                .map { Candidate(item: $0, score: qualityScore($0), reasons: reasons($0)) }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.item.addedAt > rhs.item.addedAt
                }
            let keep = ranked[0]
            let dups = Array(ranked.dropFirst())
            total += dups.count
            groups.append(Group(code: code, keep: keep, duplicates: dups))
        }

        return Report(groups: groups, totalDuplicates: total)
    }

    /// 质量打分：越高越值得保留
    private static func qualityScore(_ item: MediaItem) -> Int {
        var score = 0
        if item.isCracked { score += 40 }           // 破解优先
        if item.hasSubtitleFiles { score += 40 }    // 字幕优先
        if item.poster != nil { score += 20 }       // 小封面
        if item.fanart != nil { score += 15 }       // 大封面
        if item.nfoPath != nil || item.remoteStream != nil { score += 15 } // 数据源
        if !item.previews.isEmpty { score += 10 }   // 预览图
        if item.playProgress > 5 { score += 25 }    // 看过的不动
        if item.sourceID == nil || item.video?.size == 0 || item.video == nil {
            score -= 10                              // 远程无体积信息的略降
        } else {
            // 清晰度：按文件体积粗排（>6GB 加 30，线性向下）
            let size = item.video?.size ?? 0
            if size > 6 * 1024 * 1024 * 1024 {
                score += 30
            } else if size > 3 * 1024 * 1024 * 1024 {
                score += 20
            } else if size > 1 * 1024 * 1024 * 1024 {
                score += 10
            } else if size > 0 {
                score += 5
            }
        }
        return score
    }

    private static func reasons(_ item: MediaItem) -> [String] {
        var result: [String] = []
        if !item.isCracked { result.append("无「破解」") }
        if !item.hasSubtitleFiles { result.append("无「字幕」") }
        if item.poster == nil { result.append("缺少封面") }
        if item.fanart == nil { result.append("缺少大图") }
        if item.nfoPath == nil && item.remoteStream == nil && item.sourceID != nil && item.video?.path.hasPrefix("/item/") != true {
            result.append("缺少数据源")
        }
        if item.previews.isEmpty { result.append("无预览图") }
        if let size = item.video?.size, size > 0, size < 1024 * 1024 * 1024 {
            result.append("清晰度可能较低")
        }
        return result
    }

    // MARK: - 清理

    /// 删除选中条目
    /// - Parameter deleteRemoteFiles: 是否同时删除远程/服务器上的文件（Emby 走 API 删除，WebDAV/SMB 删文件）
    @MainActor
    static func purge(items: [MediaItem],
                      deleteRemoteFiles: Bool,
                      library: LibraryStore,
                      database: AppDatabase) async -> (removed: Int, errors: [String]) {
        var errors: [String] = []
        var removed = 0

        for item in items {
            let source = database.source(id: item.sourceID)
            let isLocal = source?.kind == .local

            if isLocal {
                await purgeLocal(item: item, errors: &errors)
            } else if source == nil {
                // 来源已被删除：只移除索引
                errors.append("\(item.code)：来源已移除，仅从媒体库删除")
                library.removeItems(withIDs: [item.id])
                removed += 1
                continue
            } else if deleteRemoteFiles {
                guard let source,
                      let provider = try? await ProviderFactory.make(source) else {
                    errors.append("\(item.code)：无法连接来源，未删除服务器文件")
                    continue
                }
                guard provider.capabilities.delete else {
                    errors.append("\(item.code)：\(source.kind.title) 不支持删除服务器文件，仅从媒体库移除")
                    library.removeItems(withIDs: [item.id])
                    removed += 1
                    continue
                }
                do {
                    try await purgeRemote(item: item, provider: provider, source: source, library: library)
                } catch {
                    // 删除失败时保留条目，避免误以为已经清理
                    errors.append("\(item.code)：删除服务器文件失败（\(describeError(error))）")
                    continue
                }
            }

            library.removeItems(withIDs: [item.id])
            removed += 1
        }

        return (removed, errors)
    }

    /// 删除远程影片及其封面 / 大图 / NFO / 字幕
    @MainActor
    private static func purgeRemote(item: MediaItem,
                                    provider: RemoteFileProvider,
                                    source: MediaSourceConfig,
                                    library: LibraryStore) async throws {
        // 媒体服务器（Emby/Jellyfin）：删除条目，服务端会连同文件一起删
        if source.kind.isMediaServer {
            if let video = item.video {
                try await provider.remove(path: video.path)
            }
            return
        }

        let root = provider.rootPath
        let shared = library.items.contains { $0.id != item.id && $0.folderPath == item.folderPath }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        // 独立番号目录：整目录删除，封面/NFO/字幕/extrafanart 一并清除
        if !shared, item.folderPath != root, item.folderPath.hasPrefix(rootPrefix) {
            try await provider.remove(path: item.folderPath)
            return
        }

        // 共享目录或来源根目录：只删属于该番号的文件
        let entries = try await provider.list(path: item.folderPath)
        let codeKey = item.code.lowercased()
        let videoBase = item.video.map { (($0.name as NSString).deletingPathExtension).lowercased() } ?? ""

        for entry in entries where !entry.isDirectory {
            let base = ((entry.name as NSString).deletingPathExtension).lowercased()
            let ownedVideo = entry.path == item.video?.path
            let related = (entry.kind == .subtitle || entry.kind == .image || entry.kind == .nfo)
                && (base.contains(codeKey) || (!videoBase.isEmpty && base.hasPrefix(videoBase)))
            if ownedVideo || related {
                try await provider.remove(path: entry.path)
            }
        }

        if !shared,
           let extra = entries.first(where: { $0.isDirectory && $0.name.lowercased() == "extrafanart" }) {
            try? await provider.remove(path: extra.path)
        }
    }

    private static func purgeLocal(item: MediaItem, errors: inout [String]) async {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: item.folderPath)

        // 1) 影片文件
        if let video = item.video {
            removeIfExists(URL(fileURLWithPath: video.path), errors: &errors)
        }

        // 2) 封面 / 大图 / NFO / 字幕 / 同番号附加文件
        //    扫描以文件夹为准，因此直接检查目录内与番号相关的文件
        if fm.fileExists(atPath: folderURL.path) {
            if let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) {
                let codeKey = item.code.lowercased()
                for file in contents {
                    let name = file.lastPathComponent
                    let base = (name as NSString).deletingPathExtension
                    let ext = (name as NSString).pathExtension.lowercased()

                    if file.lastPathComponent.lowercased() == "extrafanart" {
                        removeIfExists(file, errors: &errors)
                        continue
                    }
                    let isArtwork = ["jpg", "jpeg", "png", "webp", "heic"].contains(ext)
                    let isMeta = ext == "nfo"
                    let isSubtitle = MediaFileTypes.subtitle.contains(ext)
                    let baseMatches = base.lowercased() == codeKey
                        || base.lowercased().hasSuffix("-" + codeKey)
                        || base.lowercased().contains(codeKey)
                    if (isArtwork || isMeta || isSubtitle) && baseMatches {
                        removeIfExists(file, errors: &errors)
                    }
                }
            }

            // 3) 目录空了就删目录
            if let remaining = try? fm.contentsOfDirectory(atPath: folderURL.path),
               remaining.filter({ !$0.hasPrefix(".") }).isEmpty {
                do {
                    try fm.removeItem(at: folderURL)
                    Log.info("已删除空目录 \(folderURL.lastPathComponent)")
                } catch {
                    errors.append("删除目录失败 \(folderURL.lastPathComponent)：\(describeError(error))")
                }
            }
        }
    }

    private static func removeIfExists(_ url: URL, errors: inout [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            errors.append("删除失败 \(url.lastPathComponent)：\(describeError(error))")
        }
    }
}
