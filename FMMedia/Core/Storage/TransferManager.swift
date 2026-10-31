import Foundation

/// 本机 ↔ 远程 的传输队列（上传 / 下载 / 复制），支持暂停、继续、取消、重试
@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var tasks: [TransferTask] = []

    var maxConcurrent: Int = 2 {
        didSet { pump() }
    }

    private var runners: [UUID: Task<Void, Never>] = [:]
    private var configs: [UUID: MediaSourceConfig] = [:]
    private var sourceNames: [UUID: String] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]

    // MARK: - 入队

    @discardableResult
    func enqueueDownload(source: MediaSourceConfig,
                         remotePath: String,
                         fileName: String,
                         destinationDirectory: URL) -> UUID {
        let task = TransferTask(title: fileName,
                                direction: .download,
                                sourceID: source.id,
                                sourceName: source.name,
                                targetName: "本机",
                                remotePath: remotePath,
                                localPath: destinationDirectory.path)
        insert(task, config: source)
        return task.id
    }

    @discardableResult
    func enqueueUpload(source: MediaSourceConfig,
                       localURL: URL,
                       remoteDirectory: String) -> UUID {
        let task = TransferTask(title: localURL.lastPathComponent,
                                direction: .upload,
                                sourceID: source.id,
                                sourceName: "本机",
                                targetName: source.name,
                                remotePath: remoteDirectory,
                                localPath: localURL.path)
        var total: Int64 = 0
        if let values = try? localURL.resourceValues(forKeys: [.fileSizeKey]) {
            total = Int64(values.fileSize ?? 0)
        }
        var mutable = task
        mutable.totalBytes = total
        insert(mutable, config: source)
        return task.id
    }

    @discardableResult
    func enqueueRemoteCopy(source: MediaSourceConfig,
                           path: String,
                           fileName: String,
                           toDirectory: String) -> UUID {
        let task = TransferTask(title: fileName,
                                direction: .copy,
                                sourceID: source.id,
                                sourceName: source.name,
                                targetName: source.name,
                                remotePath: path,
                                localPath: toDirectory)
        insert(task, config: source)
        return task.id
    }

    private func insert(_ task: TransferTask, config: MediaSourceConfig) {
        tasks.insert(task, at: 0)
        configs[task.id] = config
        sourceNames[task.id] = config.name
        pump()
    }

    // MARK: - 控制

    func pause(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .running || tasks[index].status == .queued else { return }
        runners[id]?.cancel()
        runners[id] = nil
        tasks[index].status = .paused
        tasks[index].bytesPerSecond = 0
        pump()
    }

    func resume(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].status == .paused else { return }
        tasks[index].status = .queued
        tasks[index].errorMessage = nil
        pump()
    }

    func cancel(_ id: UUID) {
        runners[id]?.cancel()
        runners[id] = nil
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = .cancelled
            tasks[index].bytesPerSecond = 0
            tasks[index].finishedAt = Date()
        }
        pump()
    }

    func retry(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .queued
        tasks[index].progress = 0
        tasks[index].transferredBytes = 0
        tasks[index].errorMessage = nil
        tasks[index].finishedAt = nil
        pump()
    }

    func removeFinished() {
        tasks.removeAll { !$0.status.isActive }
    }

    func clearAll() {
        for runner in runners.values { runner.cancel() }
        runners.removeAll()
        tasks.removeAll()
        configs.removeAll()
    }

    var activeCount: Int {
        tasks.filter { $0.status == .running || $0.status == .queued }.count
    }

    // MARK: - 调度

    private func pump() {
        let limit = max(1, maxConcurrent)
        while runners.count < limit {
            guard let next = tasks.last(where: { $0.status == .queued }) else { break }
            start(next.id)
        }
    }

    private func start(_ id: UUID) {
        guard runners[id] == nil else { return }
        guard let config = configs[id],
              let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        tasks[index].status = .running
        tasks[index].startedAt = tasks[index].startedAt ?? Date()
        tasks[index].errorMessage = nil

        let task = tasks[index]

        let runner = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try ProviderFactory.make(config)
                switch task.direction {
                case .download:
                    let destination = URL(fileURLWithPath: task.localPath, isDirectory: true)
                    let fileURL = try await provider.download(path: task.remotePath, to: destination) { value in
                        Task { @MainActor in self.updateProgress(id, value: value) }
                    }
                    self.finish(id, savedURL: fileURL)
                case .upload:
                    let localURL = URL(fileURLWithPath: task.localPath)
                    _ = try await provider.upload(localURL: localURL, to: task.remotePath) { value in
                        Task { @MainActor in self.updateProgress(id, value: value) }
                    }
                    self.finish(id, savedURL: nil)
                case .copy:
                    try await provider.copy(path: task.remotePath, toDirectory: task.localPath)
                    self.finish(id, savedURL: nil)
                }
            } catch {
                self.fail(id, error: error)
            }
        }
        runners[id] = runner
    }

    private func updateProgress(_ id: UUID, value: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        tasks[index].progress = clamped

        if tasks[index].totalBytes > 0 {
            tasks[index].transferredBytes = Int64(Double(tasks[index].totalBytes) * clamped)
        }

        let now = Date()
        if let sample = samples[id] {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed > 0.5 {
                let delta = tasks[index].transferredBytes - sample.bytes
                if delta > 0 {
                    tasks[index].bytesPerSecond = Double(delta) / elapsed
                }
                samples[id] = (tasks[index].transferredBytes, now)
            }
        } else {
            samples[id] = (tasks[index].transferredBytes, now)
        }
    }

    private func finish(_ id: UUID, savedURL: URL?) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = .completed
            tasks[index].progress = 1
            tasks[index].bytesPerSecond = 0
            tasks[index].finishedAt = Date()
            if let savedURL {
                tasks[index].localPath = savedURL.path
            }
        }
        runners[id] = nil
        samples[id] = nil
        pump()
    }

    private func fail(_ id: UUID, error: Error) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            if tasks[index].status == .paused || tasks[index].status == .cancelled {
                runners[id] = nil
                return
            }
            tasks[index].status = .failed
            tasks[index].errorMessage = describeError(error)
            tasks[index].bytesPerSecond = 0
            tasks[index].finishedAt = Date()
        }
        runners[id] = nil
        samples[id] = nil
        pump()
    }
}
