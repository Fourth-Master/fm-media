import Foundation

/// 带进度的下载 / 上传（支持 Task 取消）
enum HTTPFileTransfer {
    static func download(url: URL,
                         headers: [String: String],
                         to destinationDirectory: URL,
                         preferredName: String? = nil,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate()
        delegate.destinationDirectory = destinationDirectory
        delegate.preferredName = preferredName
        delegate.onProgress = progress

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.downloadTask(with: request)

        do {
            let fileURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    delegate.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            session.finishTasksAndInvalidate()
            return fileURL
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    static func upload(url: URL,
                       method: String = "PUT",
                       headers: [String: String],
                       from localURL: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let delegate = UploadDelegate()
        delegate.onProgress = progress

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.uploadTask(with: request, fromFile: localURL)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            session.finishTasksAndInvalidate()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    // MARK: - Delegates

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Double) -> Void)?
        var continuation: CheckedContinuation<URL, Error>?
        var destinationDirectory: URL?
        var preferredName: String?
        private var moveError: Error?
        private var outputURL: URL?

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let directory = destinationDirectory else { return }
            var name = preferredName
            if name == nil {
                name = downloadTask.response?.suggestedFilename
                    ?? downloadTask.originalRequest?.url?.lastPathComponent
                    ?? "download"
            }
            let safeName = (name ?? "download").sanitizedFileName
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = FileStore.uniqueDestination(for: safeName, in: directory)
                try FileManager.default.moveItem(at: location, to: destination)
                outputURL = destination
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    continuation.resume(throwing: AppError.message("下载已取消"))
                } else {
                    continuation.resume(throwing: AppError.network(describeError(error)))
                }
                return
            }
            if let moveError {
                continuation.resume(throwing: AppError.fileSystem(describeError(moveError)))
                return
            }
            if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation.resume(throwing: AppError.network("下载失败：HTTP \(http.statusCode)"))
                return
            }
            guard let outputURL else {
                continuation.resume(throwing: AppError.fileSystem("下载文件写入失败"))
                return
            }
            continuation.resume(returning: outputURL)
        }
    }

    private final class UploadDelegate: NSObject, URLSessionTaskDelegate {
        var onProgress: ((Double) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            onProgress?(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    continuation.resume(throwing: AppError.message("上传已取消"))
                } else {
                    continuation.resume(throwing: AppError.network(describeError(error)))
                }
                return
            }
            if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation.resume(throwing: AppError.network("上传失败：HTTP \(http.statusCode)"))
                return
            }
            continuation.resume()
        }
    }
}
