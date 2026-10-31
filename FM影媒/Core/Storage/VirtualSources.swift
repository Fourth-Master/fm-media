import Foundation

/// 应用内虚拟来源（不参与持久化）
enum VirtualSources {
    static let downloads = MediaSourceConfig(name: "本机下载",
                                             kind: .local,
                                             localPath: FileStore.downloads.path)
}
