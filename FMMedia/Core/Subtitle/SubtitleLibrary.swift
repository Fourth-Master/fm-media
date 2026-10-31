import Foundation

/// 保存每个影片关联的下载字幕，下次播放自动带上
@MainActor
final class SubtitleLibrary: ObservableObject {
    static let shared = SubtitleLibrary()

    struct Record: Codable, Hashable, Identifiable {
        var id: String { path }
        var path: String
        var name: String
        var addedAt: Date
        var source: String
    }

    @Published private(set) var storage: [String: [Record]] = [:]

    private let fileName = "subtitles.json"

    init() {
        storage = JSONStore.load([String: [Record]].self, from: fileName) ?? [:]
    }

    func items(for itemID: String) -> [MediaFileRef] {
        let records = storage[itemID] ?? []
        return records.compactMap { record in
            guard FileManager.default.fileExists(atPath: record.path) else { return nil }
            return MediaFileRef(path: record.path,
                                name: record.name,
                                size: FileStore.size(of: URL(fileURLWithPath: record.path)))
        }
    }

    func records(for itemID: String) -> [Record] {
        (storage[itemID] ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    func add(itemID: String, fileURL: URL, name: String, source: String = "手动导入") -> Record {
        var records = storage[itemID] ?? []
        if let existing = records.first(where: { $0.name == name }) {
            return existing
        }
        let record = Record(path: fileURL.path, name: name, addedAt: Date(), source: source)
        records.append(record)
        storage[itemID] = records
        persist()
        return record
    }

    func remove(itemID: String, record: Record, deleteFile: Bool = false) {
        guard var records = storage[itemID] else { return }
        records.removeAll { $0.path == record.path }
        storage[itemID] = records
        if deleteFile {
            try? FileManager.default.removeItem(atPath: record.path)
        }
        persist()
    }

    /// 保存字幕文本并关联到条目
    @discardableResult
    func saveText(itemID: String, name: String, text: String, source: String) -> Record? {
        let base = name.deletingPathExtension.sanitizedFileName
        let destination = FileStore.uniqueDestination(for: "\(base).srt", in: FileStore.subtitles)
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return add(itemID: itemID, fileURL: destination, name: destination.lastPathComponent, source: source)
        } catch {
            return nil
        }
    }

    var totalCount: Int {
        storage.values.reduce(0) { $0 + $1.count }
    }

    func clearAll() {
        storage = [:]
        try? FileManager.default.removeItem(at: FileStore.subtitles)
        FileStore.ensure(FileStore.subtitles)
        persist()
    }

    private func persist() {
        JSONStore.save(storage, to: fileName)
    }
}
