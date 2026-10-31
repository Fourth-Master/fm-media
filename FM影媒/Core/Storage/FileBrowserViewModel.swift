import Foundation

/// 播放请求：统一描述一次播放会话
struct PlaybackRequest: Identifiable, Hashable {
    let id: UUID = UUID()
    var stream: StreamDescriptor
    var media: MediaItem? = nil
    var title: String = ""
    var subtitles: [MediaFileRef] = []
    var sourceID: UUID? = nil
    var startAt: Double = 0
    /// 远程来源的同名字幕（播放时按需下载）
    var remoteSubtitles: [StreamDescriptor] = []

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let media { return media.displayTitle }
        return stream.title.isEmpty ? "视频" : stream.title
    }
}

/// 全局播放器入口，任何页面都可以发起播放
@MainActor
final class PlayerPresenter: ObservableObject {
    @Published var request: PlaybackRequest?

    /// 用于懒解析远程条目的播放地址（SMB / 云盘等扫描时不取直链）
    weak var database: AppDatabase?

    func play(_ request: PlaybackRequest) {
        self.request = request
    }

    func play(media: MediaItem, startAt: Double = 0) {
        Task { await playResolved(media: media, startAt: startAt) }
    }

    private func playResolved(media: MediaItem, startAt: Double) async {
        var stream = media.stream

        // 扫描时未取直链的远程条目（SMB / 云盘）在播放时解析
        if stream == nil, let sourceID = media.sourceID, let source = database?.source(id: sourceID) {
            if let provider = try? ProviderFactory.make(source), let path = media.video?.path {
                stream = try? await provider.stream(path: path)
            }
        }

        guard let stream else { return }

        // 远程条目的字幕文件不在本机：播放时再下载
        let localSubtitles = media.remoteStream == nil ? media.subtitles : []

        play(PlaybackRequest(stream: stream,
                             media: media,
                             title: media.displayTitle,
                             subtitles: localSubtitles + SubtitleLibrary.shared.items(for: media.id),
                             sourceID: media.sourceID,
                             startAt: startAt,
                             remoteSubtitles: media.remoteSubtitleStreams))
    }

    func dismiss() {
        request = nil
    }
}

/// 单个目录的文件浏览状态
@MainActor
final class FileBrowserViewModel: ObservableObject {
    struct Crumb: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String
    }

    let source: MediaSourceConfig
    @Published var crumbs: [Crumb] = []
    @Published var entries: [FileEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var ascending = true
    @Published var selectMode = false
    @Published var selection: Set<String> = []

    private var provider: RemoteFileProvider?
    private var loaded = false

    init(source: MediaSourceConfig) {
        self.source = source
    }

    var capabilities: ProviderCapabilities {
        provider?.capabilities ?? .readOnly
    }

    var currentPath: String {
        crumbs.last?.path ?? provider?.rootPath ?? "/"
    }

    var currentName: String {
        crumbs.last?.name ?? source.name
    }

    var filteredEntries: [FileEntry] {
        var result = entries
        let keyword = query.trimmed
        if !keyword.isEmpty {
            result = result.filter { $0.displayName.containsIgnoringCase(keyword) }
        }
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return result
    }

    func loadInitial() async {
        guard !loaded else { return }
        loaded = true
        do {
            let provider = try ProviderFactory.make(source)
            self.provider = provider
            let root = provider.rootPath
            crumbs = [Crumb(name: source.name, path: root)]
            await reload()
        } catch {
            errorMessage = describeError(error)
        }
    }

    func refresh() async {
        await reload()
    }

    private func reload() async {
        guard let provider else { return }
        isLoading = true
        errorMessage = nil
        do {
            entries = try await provider.list(path: currentPath)
        } catch {
            entries = []
            errorMessage = describeError(error)
        }
        isLoading = false
    }

    func open(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        crumbs.append(Crumb(name: entry.displayName, path: entry.path))
        selection.removeAll()
        await reload()
    }

    func goUp() async {
        guard crumbs.count > 1 else { return }
        crumbs.removeLast()
        selection.removeAll()
        await reload()
    }

    func jump(to crumb: Crumb) async {
        guard let index = crumbs.firstIndex(where: { $0.path == crumb.path }) else { return }
        crumbs = Array(crumbs.prefix(index + 1))
        selection.removeAll()
        await reload()
    }

    func makeFolder(name: String) async {
        guard let provider else { return }
        let folderPath = join(directory: currentPath, name: name.sanitizedFileName)
        do {
            try await provider.makeDirectory(path: folderPath)
            await reload()
        } catch {
            errorMessage = describeError(error)
        }
    }

    func delete(_ targets: [FileEntry]) async {
        guard let provider else { return }
        for entry in targets {
            do {
                try await provider.remove(path: entry.path)
            } catch {
                errorMessage = describeError(error)
            }
        }
        selection.removeAll()
        await reload()
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        guard let provider else { return }
        do {
            try await provider.rename(path: entry.path, to: newName.sanitizedFileName)
            await reload()
        } catch {
            errorMessage = describeError(error)
        }
    }

    func stream(for entry: FileEntry) async throws -> StreamDescriptor {
        guard let provider else { throw AppError.notConfigured("来源未就绪") }
        return try await provider.stream(path: entry.path)
    }

    func playbackRequest(for entry: FileEntry) async throws -> PlaybackRequest {
        let descriptor = try await stream(for: entry)
        return PlaybackRequest(stream: descriptor,
                               media: nil,
                               title: entry.displayName,
                               subtitles: [],
                               sourceID: source.id)
    }

    private func join(directory: String, name: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + name }
        if directory.hasSuffix("/") { return directory + "/" + name }
        return directory + "/" + name
    }
}

extension Notification.Name {
    static let fmShowTransfers = Notification.Name("fm.show.transfers")
}
