import Foundation

/// 数据源仓库（持久化到 App Support）
@MainActor
final class AppDatabase: ObservableObject {
    @Published var sources: [MediaSourceConfig] {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?
    private let fileName = "sources.json"

    init() {
        let loaded: [MediaSourceConfig] = JSONStore.load([MediaSourceConfig].self, from: fileName) ?? []
        sources = loaded
        LocalAccessManager.shared.activateAll(loaded)
    }

    func source(id: UUID?) -> MediaSourceConfig? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    func add(_ source: MediaSourceConfig) {
        sources.append(source)
        LocalAccessManager.shared.activate(source)
    }

    func update(_ source: MediaSourceConfig) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            add(source)
            return
        }
        sources[index] = source
        LocalAccessManager.shared.activate(source)
    }

    func remove(_ source: MediaSourceConfig) {
        sources.removeAll { $0.id == source.id }
        SecretStore.delete(source.secretKey)
        LocalAccessManager.shared.deactivate(source.id)
    }

    var localSources: [MediaSourceConfig] {
        sources.filter { $0.kind == .local }
    }

    var mediaServers: [MediaSourceConfig] {
        sources.filter { $0.kind.isMediaServer }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = sources
        saveTask = Task { [snapshot] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            JSONStore.save(snapshot, to: self.fileName)
        }
    }
}
