import Foundation

public enum RemoteSyncError: Error, Equatable, Sendable {
    case badURL
    case http(status: Int)
    case timeout
    case tooLarge(bytes: Int)
    case undecodable
}

public struct RemoteFetch: Sendable, Equatable {
    public let content: String
    public let etag: String?
    public let notModified: Bool
}

public protocol RemoteFetching: Sendable {
    func fetch(url: String, etag: String?) async -> Result<RemoteFetch, RemoteSyncError>
}

/// 真实现：ETag 条件请求 + 超时 + 体积上限。
public struct URLSessionRemoteFetcher: RemoteFetching {
    public static let maxBytes = 2 * 1024 * 1024
    public static let timeout: TimeInterval = 15

    public init() {}

    public func fetch(url: String, etag: String?) async -> Result<RemoteFetch, RemoteSyncError> {
        guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true else {
            return .failure(.badURL)
        }
        var req = URLRequest(url: u, timeoutInterval: Self.timeout)
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.undecodable) }
            if http.statusCode == 304 {
                return .success(RemoteFetch(content: "", etag: etag, notModified: true))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(status: http.statusCode))
            }
            guard data.count <= Self.maxBytes else {
                return .failure(.tooLarge(bytes: data.count))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.undecodable)
            }
            return .success(RemoteFetch(content: text,
                                        etag: http.value(forHTTPHeaderField: "ETag"),
                                        notModified: false))
        } catch let e as URLError {
            return .failure(e.code == .timedOut ? .timeout : .http(status: -1))
        } catch {
            return .failure(.undecodable)
        }
    }
}

public enum SyncOutcome: Sendable, Equatable {
    case updated(content: String, etag: String?)
    case notModified
    /// 拉取失败但有缓存：继续用缓存参与编译，离线不该让规则失效
    case usedCache(content: String, reason: RemoteSyncError)
    case failed(RemoteSyncError)
}

public struct RemoteSync: Sendable {
    private let fetcher: any RemoteFetching

    public init(fetcher: any RemoteFetching = URLSessionRemoteFetcher()) {
        self.fetcher = fetcher
    }

    public func sync(url: String, etag: String?, cached: String?) async -> SyncOutcome {
        let result = await fetcher.fetch(url: url, etag: etag)
        switch result {
        case .success(let f):
            if f.notModified { return .notModified }
            return .updated(content: f.content, etag: f.etag)
        case .failure(let e):
            if let cached, !cached.isEmpty { return .usedCache(content: cached, reason: e) }
            return .failed(e)
        }
    }
}
