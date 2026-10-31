import Foundation
import SwiftUI

/// 智能媒体库：扫描、筛选、排序、收藏、续播
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var favorites: Set<String> = [] {
        didSet { persistFavorites() }
    }
    @Published var isScanning = false
    @Published var scanStatus = ""
    @Published var lastError: String?
    @Published var lastScan: Date?
    private(set) var lastScanAppVersion: String? = JSONStore.load(String.self, from: "scanVersion.json")
    /// 每个来源的扫描签名（用于增量扫描，跳过未变化的来源）
    private var scanSignatures: [String: String] = JSONStore.load([String: String].self, from: "scanSignatures.json") ?? [:]
    /// 强制全量扫描标记
    private var forceScanRequested = false
    @Published var query: String = ""
    @Published var filter: LibraryFilter = .all
    /// 题材分类（来自数据源 genre）
    @Published var selectedGenre: String? = nil

    static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    private let libraryFile = "library.json"
    private let favoritesFile = "favorites.json"

    init() {
        items = JSONStore.load([MediaItem].self, from: libraryFile) ?? []
        favorites = Set(JSONStore.load([String].self, from: favoritesFile) ?? [])
        lastScan = JSONStore.load(Date.self, from: "lastScan.json")
    }

    // MARK: - 扫描

    func scan(sources: [MediaSourceConfig], force: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil

        // 可自动扫描的来源：本机目录 + WebDAV / SMB；云盘与媒体服务器另行处理
        let scannable = sources.filter { $0.isEnabled && ($0.kind == .local || $0.kind == .webdav || $0.kind == .smb) }

        // 保留不可自动扫描来源（如 Emby 导入）的条目
        let keptItems = items.filter { item in
            guard let sourceID = item.sourceID else { return false }
            return !scannable.contains { $0.id == sourceID }
        }

        var merged: [String: MediaItem] = [:]
        for item in keptItems { merged[item.id] = item }

        for (index, source) in scannable.enumerated() {
            // 增量扫描：已扫描过且非强制的来源跳过
            if !force, scanSignatures[source.id.uuidString] != nil {
                scanStatus = "跳过 \(source.name)（已扫描）"
                continue
            }
            scanStatus = "正在扫描 \(source.name)（\(index + 1)/\(scannable.count)）"
            if source.kind == .local {
                let summary = await Task.detached(priority: .userInitiated) {
                    LibraryScanner.scanLocal(source: source)
                }.value
                for item in summary.items { merged[item.id] = item }
                if !summary.skippedFolders.isEmpty {
                    Log.info("跳过 \(summary.skippedFolders.count) 个无视频文件夹")
                }
            } else {
                let scanned = await Task.detached(priority: .userInitiated) { [weak self] in
                    await RemoteLibraryScanner.scan(source: source, progress: { text in
                        Task { @MainActor in self?.scanStatus = text }
                    })
                }.value
                for item in scanned { merged[item.id] = item }
            }
        }

        var result = Array(merged.values)
        // 恢复播放进度
        let progress = playProgressMap()
        for index in result.indices {
            if let record = progress[result[index].id] {
                result[index].playProgress = record.seconds
                result[index].lastPlayed = record.date
            }
        }

        items = result.sorted { $0.addedAt > $1.addedAt }
        lastScan = Date()
        isScanning = false
        scanStatus = ""
        persistItems()
        JSONStore.save(lastScan ?? Date(), to: "lastScan.json")
        lastScanAppVersion = LibraryStore.currentAppVersion
        for source in scannable {
            scanSignatures[source.id.uuidString] = "scanned"
        }
        JSONStore.save(scanSignatures, to: "scanSignatures.json")
        JSONStore.save(lastScanAppVersion ?? "", to: "scanVersion.json")
    }

    /// 从 Emby 系媒体服务器导入
    func importFromServer(_ source: MediaSourceConfig) async {
        isScanning = true
        scanStatus = "正在从 \(source.name) 拉取媒体库…"
        defer {
            isScanning = false
            scanStatus = ""
        }
        do {
            let provider = try ProviderFactory.make(source)
            guard let emby = provider as? EmbyProvider else {
                throw AppError.unsupported("该来源不支持导入媒体库")
            }
            let imported = try await emby.fetchLibraryItems()
            var merged = items.filter { $0.sourceID != source.id }
            merged.append(contentsOf: imported)
            items = merged.sorted { $0.addedAt > $1.addedAt }
            persistItems()
        } catch {
            lastError = describeError(error)
        }
    }

    func removeSourceItems(_ sourceID: UUID) {
        items.removeAll { $0.sourceID == sourceID }
        persistItems()
    }

    /// 标记来源需要重新扫描（添加或编辑来源后调用）
    func markSourceForRescan(_ sourceID: UUID) {
        scanSignatures.removeValue(forKey: sourceID.uuidString)
        JSONStore.save(scanSignatures, to: "scanSignatures.json")
    }

    /// 强制下次扫描全量
    func forceFullRescan() {
        scanSignatures.removeAll()
        JSONStore.save(scanSignatures, to: "scanSignatures.json")
    }

    func removeItems(withIDs ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        persistItems()
    }

    func clearLibrary() {
        items = []
        persistItems()
    }

    // MARK: - 查询

    func filteredItems(filter: LibraryFilter,
                       sort: LibrarySort,
                       showUnrecognized: Bool = true) -> [MediaItem] {
        var result = items

        if !showUnrecognized {
            result = result.filter { $0.isRecognized }
        }

        switch filter {
        case .all, .recent:
            break
        case .cracked:
            result = result.filter { $0.isCracked }
        case .subtitled:
            result = result.filter { $0.hasSubtitleFiles }
        case .favorites:
            result = result.filter { favorites.contains($0.id) }
        }

        let keyword = query.trimmed
        if !keyword.isEmpty {
            result = result.filter { item in
                item.code.containsIgnoringCase(keyword)
                    || item.title.containsIgnoringCase(keyword)
                    || item.rawName.containsIgnoringCase(keyword)
                    || item.actors.contains { $0.name.containsIgnoringCase(keyword) }
                    || item.genres.contains { $0.containsIgnoringCase(keyword) }
                    || item.tags.contains { $0.containsIgnoringCase(keyword) }
            }
        }

        switch sort {
        case .recent: result.sort { $0.addedAt > $1.addedAt }
        case .code: result.sort { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
        case .title: result.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .rating: result.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .size: result.sort { ($0.video?.size ?? 0) > ($1.video?.size ?? 0) }
        case .duration: result.sort { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
        }

        if filter == .recent {
            let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 14)
            result = result.filter { $0.addedAt > cutoff }
        }
        return result
    }

    func item(id: String) -> MediaItem? {
        items.first { $0.id == id }
    }

    func toggleFavorite(_ item: MediaItem) {
        favorites.toggleMembership(item.id)
    }

    var stats: (total: Int, cracked: Int, subtitled: Int, favorites: Int, size: Int64) {
        let size = items.reduce(Int64(0)) { $0 + ($1.video?.size ?? 0) }
        return (items.count,
                items.filter { $0.isCracked }.count,
                items.filter { $0.hasSubtitleFiles }.count,
                items.filter { favorites.contains($0.id) }.count,
                size)
    }

    // MARK: - 播放进度

    private struct ProgressRecord: Codable {
        var seconds: Double
        var date: Date
    }

    private func playProgressMap() -> [String: ProgressRecord] {
        JSONStore.load([String: ProgressRecord].self, from: "progress.json") ?? [:]
    }

    func updateProgress(itemID: String, seconds: Double) {
        var map = playProgressMap()
        map[itemID] = ProgressRecord(seconds: seconds, date: Date())
        JSONStore.save(map, to: "progress.json")
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].playProgress = seconds
            items[index].lastPlayed = Date()
        }
    }

    /// 移出首页「继续观看」：清除播放进度
    func clearProgress(itemID: String) {
        var map = playProgressMap()
        map.removeValue(forKey: itemID)
        JSONStore.save(map, to: "progress.json")
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].playProgress = 0
            items[index].lastPlayed = nil
        }
    }

    func progress(for itemID: String) -> Double {
        playProgressMap()[itemID]?.seconds ?? 0
    }

    // MARK: - 持久化

    private func persistItems() {
        JSONStore.save(items, to: libraryFile)
    }

    private func persistFavorites() {
        JSONStore.save(Array(favorites), to: favoritesFile)
    }
}
