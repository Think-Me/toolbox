import Foundation
import Testing
@testable import ToolboxKit

/// class 而非 struct：要记录收到的 etag，struct 里改不了自己的属性
private final class StubFetcher: RemoteFetching, @unchecked Sendable {
    let result: Result<RemoteFetch, RemoteSyncError>
    private(set) var seenEtag: String??
    init(_ r: Result<RemoteFetch, RemoteSyncError>) { result = r }
    func fetch(url: String, etag: String?) async -> Result<RemoteFetch, RemoteSyncError> {
        seenEtag = etag
        return result
    }
}

@Test func freshFetchReturnsUpdated() async {
    let sync = RemoteSync(fetcher: StubFetcher(.success(RemoteFetch(content: "1.2.3.4 a.com", etag: "W/\"x1\"", notModified: false))))
    let r = await sync.sync(url: "https://x/y.txt", etag: nil, cached: nil)
    guard case .updated(let content, let etag) = r else { Issue.record("应 updated"); return }
    #expect(content == "1.2.3.4 a.com")
    #expect(etag == "W/\"x1\"")
}

@Test func notModifiedPropagates() async {
    let sync = RemoteSync(fetcher: StubFetcher(.success(RemoteFetch(content: "", etag: "e", notModified: true))))
    if case .notModified = await sync.sync(url: "u", etag: "e", cached: "old") { }
    else { Issue.record("应 notModified") }
}

@Test func failureWithCacheFallsBackToCache() async {
    // 断网/远端 500 时规则不能凭空消失，否则用户一同步就把 hosts 清空了
    let sync = RemoteSync(fetcher: StubFetcher(.failure(.timeout)))
    let r = await sync.sync(url: "u", etag: nil, cached: "9.9.9.9 cached.local")
    guard case .usedCache(let content, let reason) = r else { Issue.record("应 usedCache"); return }
    #expect(content == "9.9.9.9 cached.local")
    #expect(reason == .timeout)
}

@Test func failureWithoutCacheIsFailed() async {
    let sync = RemoteSync(fetcher: StubFetcher(.failure(.http(status: 404))))
    if case .failed(.http(status: 404)) = await sync.sync(url: "u", etag: nil, cached: nil) { }
    else { Issue.record("应 failed") }
}

@Test func etagIsForwardedToFetcher() async {
    let stub = StubFetcher(.success(RemoteFetch(content: "", etag: nil, notModified: true)))
    _ = await RemoteSync(fetcher: stub).sync(url: "u", etag: "prev-etag", cached: nil)
    #expect(stub.seenEtag == .some("prev-etag"))
}

@Test func badURLIsRejectedBeforeAnyNetworkCall() async {
    let sync = RemoteSync(fetcher: URLSessionRemoteFetcher())
    if case .failed(.badURL) = await sync.sync(url: "ftp://x/y", etag: nil, cached: nil) { }
    else { Issue.record("非 http(s) 必须拒绝") }
}

@Test func oversizedResponseIsRejected() async {
    let big = String(repeating: "1.1.1.1 host", count: 300_000)
    let sync = RemoteSync(fetcher: StubFetcher(.failure(.tooLarge(bytes: big.utf8.count))))
    if case .failed(.tooLarge) = await sync.sync(url: "u", etag: nil, cached: nil) { }
    else { Issue.record("超大响应必须拒绝") }
}
