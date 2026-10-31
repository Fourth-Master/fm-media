import Foundation

enum Log {
    static var verbose = false

    static func info(_ message: String) {
        #if DEBUG
        print("[FM] \(message)")
        #endif
    }

    static func error(_ message: String, _ error: Error? = nil) {
        #if DEBUG
        if let error {
            print("[FM][E] \(message): \(error.localizedDescription)")
        } else {
            print("[FM][E] \(message)")
        }
        #endif
    }
}

enum AppError: LocalizedError {
    case message(String)
    case unsupported(String)
    case notConfigured(String)
    case network(String)
    case auth(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unsupported(let text): return text
        case .notConfigured(let text): return text
        case .network(let text): return text
        case .auth(let text): return text
        case .fileSystem(let text): return text
        }
    }
}

/// 把任意 Error 转成可展示文案
func describeError(_ error: Error) -> String {
    if let appError = error as? AppError {
        return appError.errorDescription ?? "未知错误"
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "网络未连接"
        case NSURLErrorTimedOut: return "连接超时"
        case NSURLErrorCannotFindHost: return "无法解析服务器地址"
        case NSURLErrorCannotConnectToHost: return "无法连接服务器"
        case NSURLErrorSecureConnectionFailed: return "TLS 握手失败，请检查证书或改用 HTTP"
        case NSURLErrorUserAuthenticationRequired: return "需要身份验证"
        case NSURLErrorCancelled: return "已取消"
        default: return ns.localizedDescription
        }
    }
    return ns.localizedDescription
}
