import Foundation
import Testing
@testable import ToolboxKit

private func tmpFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("proxystore-\(UUID().uuidString).json")
}

@Test func roundTripsLibrary() throws {
    let url = tmpFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = ProxyStore(file: url)
    var lib = ProxyLibrary()
    let n = ProxyNode(name: "东京", kind: .vless, server: "1.2.3.4", port: 443, uuid: "u",
                      transport: .ws, path: "/x", useTLS: true, sni: "a.com")
    lib = ProxyStore.adding(n, to: lib)
    lib.runtime.routingMode = .global
    lib.runtime.socksPort = 12345
    try store.save(lib)
    #expect(store.load() == lib)
    #expect(store.load().activeNode?.name == "东京")
}

@Test func missingFileLoadsEmpty() {
    let store = ProxyStore(file: tmpFile())   // 不存在
    let l = store.load()
    #expect(l.nodes.isEmpty)
    #expect(l.runtime.socksPort == 10808)
}

@Test func corruptFileIsIsolatedAndReturnsEmpty() throws {
    let url = tmpFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json at all {{{".utf8).write(to: url)
    let l = ProxyStore(file: url).load()
    #expect(l.nodes.isEmpty)
    // 坏文件被改名隔离，原件不再原样留着
    let fm = FileManager.default
    let leftovers = (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
    #expect(leftovers.contains { $0.hasPrefix(url.lastPathComponent) && $0.contains("corrupt") })
}

@Test func nodeWithMissingFieldsStillDecodes() throws {
    // 未来给 ProxyNode 加字段后，老库缺这些字段必须能解、缺失项回落默认，
    // 绝不能整份 nodes.json 解不开被重置（本项目反复踩的坑）
    let url = tmpFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let partial = """
    {"nodes":[{"name":"旧节点","kind":"vmess","server":"9.9.9.9","port":"80"}],"runtime":{}}
    """
    try partial.data(using: .utf8)!.write(to: url)
    let l = ProxyStore(file: url).load()
    #expect(l.nodes.count == 1)
    #expect(l.nodes[0].name == "旧节点")
    #expect(l.nodes[0].transport == .tcp)          // 缺字段回落默认
    #expect(l.nodes[0].alterID == "0")
    #expect(l.runtime.httpPort == 10809)           // runtime:{} 也回落默认
}

@Test func crudHelpers() {
    let a = ProxyNode(name: "A", kind: .vmess, server: "a", port: 1, uuid: "u")
    let b = ProxyNode(name: "B", kind: .trojan, server: "b", port: 2, password: "p")
    var lib = ProxyLibrary()
    lib = ProxyStore.adding(a, to: lib)
    lib = ProxyStore.adding(b, to: lib)
    #expect(lib.activeNodeID == a.id)              // 第一个自动选中
    lib = ProxyStore.settingActive(b.id, in: lib)
    #expect(lib.activeNode?.name == "B")
    lib = ProxyStore.removing(b.id, from: lib)
    #expect(lib.nodes.count == 1)
    #expect(lib.activeNode?.name == "A")           // 删掉选中的会回落到剩下的
    var edited = a; edited.name = "A2"
    lib = ProxyStore.replacing(edited, in: lib)
    #expect(lib.nodes[0].name == "A2")
}

@Test func autoStartNeedsUsableNode() {
    var lib = ProxyLibrary()
    #expect(!ProxyViewModel.hasUsableNode(lib))        // 空库不自动开

    let node = ProxyNode(name: "A", kind: .vmess, server: "a", port: 1, uuid: "u")
    lib = ProxyStore.adding(node, to: lib)
    #expect(ProxyViewModel.hasUsableNode(lib))         // 手动模式：有选中节点

    lib = ProxyStore.settingActive(nil, in: lib)
    #expect(!ProxyViewModel.hasUsableNode(lib))        // 手动模式：没选中

    lib.runtime.autoSwitch = true
    #expect(ProxyViewModel.hasUsableNode(lib))         // 自动切换：候选组非空

    lib.nodes[0].balancerCandidate = false
    #expect(!ProxyViewModel.hasUsableNode(lib))        // 自动切换：没有候选
}
