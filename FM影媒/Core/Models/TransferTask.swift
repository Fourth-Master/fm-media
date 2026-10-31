import Foundation

enum TransferDirection: String, Codable, Hashable {
    case download   // 远程 → 本机
    case upload     // 本机 → 远程
    case copy       // 本机内部复制 / 远程内部复制

    var title: String {
        switch self {
        case .download: return "下载"
        case .upload: return "上传"
        case .copy: return "复制"
        }
    }
}

enum TransferStatus: String, Codable, Hashable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "传输中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool { self == .queued || self == .running || self == .paused }
}

struct TransferTask: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var title: String
    var direction: TransferDirection
    var sourceID: UUID?
    var targetSourceID: UUID?
    var sourceName: String
    var targetName: String
    var remotePath: String
    var localPath: String
    var status: TransferStatus = .queued
    var progress: Double = 0
    var totalBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var errorMessage: String? = nil
    var createdAt: Date = Date()
    var startedAt: Date? = nil
    var finishedAt: Date? = nil

    var speedText: String {
        guard bytesPerSecond > 0 else { return "" }
        return "\(Int64(bytesPerSecond).fileSizeText)/s"
    }

    var sizeText: String {
        totalBytes > 0 ? totalBytes.fileSizeText : ""
    }
}
