import SwiftUI
import UIKit

/// 支持鉴权头的图片加载与缓存（封面 / 预览图）
final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let ioQueue = DispatchQueue(label: "fm.image.io", qos: .utility)

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.countLimit = 400
    }

    func cachedImage(for ref: ImageRef) -> UIImage? {
        memory.object(forKey: ref.cacheKey as NSString)
    }

    func image(for ref: ImageRef, maxPixel: CGFloat = 1200) async -> UIImage? {
        if let cached = cachedImage(for: ref) { return cached }

        if ref.isLocalFile {
            let key = ref.cacheKey
            let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                ioQueue.async {
                    let loaded = UIImage(contentsOfFile: ref.url.path)
                    if let loaded { self.memory.setObject(loaded, forKey: key as NSString) }
                    continuation.resume(returning: loaded)
                }
            }
            return image
        }

        let diskURL = diskCacheURL(for: ref)
        if let data = try? Data(contentsOf: diskURL), let image = UIImage(data: data) {
            memory.setObject(image, forKey: ref.cacheKey as NSString)
            return image
        }

        var request = URLRequest(url: ref.url)
        for (key, value) in ref.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let image = UIImage(data: data) else { return nil }
            memory.setObject(image, forKey: ref.cacheKey as NSString)
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
            return image
        } catch {
            return nil
        }
    }

    func clearCaches() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: FileStore.imageCache)
        FileStore.ensure(FileStore.imageCache)
    }

    func diskCacheSize() -> Int64 {
        FileStore.directorySize(of: FileStore.imageCache)
    }

    private func diskCacheURL(for ref: ImageRef) -> URL {
        let ext = ref.url.pathExtension.isEmpty ? "img" : ref.url.pathExtension
        return FileStore.imageCache.appendingPathComponent("\(Self.hash(ref.cacheKey)).\(ext)")
    }

    private static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }
}

/// 异步图片视图
struct FMImageView: View {
    let ref: ImageRef?
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(FMTheme.surfaceHigh)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(FMTheme.textTertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(FMTheme.textTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: ref?.cacheKey) {
            failed = false
            image = nil
            guard let ref else {
                failed = true
                return
            }
            if let cached = RemoteImageLoader.shared.cachedImage(for: ref) {
                image = cached
                return
            }
            let loaded = await RemoteImageLoader.shared.image(for: ref)
            if Task.isCancelled { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// 本机文件缩略图（图片 / 视频首帧）
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: UIImage] = [:]

    func image(for url: URL, kind: FileKind) -> UIImage? {
        let key = url.path
        if let cached = cache[key] { return cached }
        let image: UIImage?
        if kind == .image {
            image = UIImage(contentsOfFile: url.path)
        } else if kind == .video {
            image = VideoThumbnailer.firstFrame(url: url)
        } else {
            image = nil
        }
        if let image {
            cache[key] = image
            if cache.count > 200 { cache.removeAll() }
        }
        return image
    }
}
