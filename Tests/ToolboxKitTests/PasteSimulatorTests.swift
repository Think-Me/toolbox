import AppKit
import Foundation
import Testing
@testable import ToolboxKit

@MainActor
private final class FakeDriver: PasteDriving {
    var calls: [String] = []
    var activateResult = true
    var keystrokeResult = true
    /// activate 被调用时"面板是否还开着"。真 bug 就是面板没先关，
    /// 导致合成的 ⌘V 被打到自己的 key window 上而不是目标 App。
    var panelStillOpenAtActivate: Bool?

    func activate(_ app: NSRunningApplication?) async -> Bool {
        calls.append("activate")
        panelStillOpenAtActivate = panelOpenProbe?()
        return activateResult
    }

    var panelOpenProbe: (() -> Bool)?
    func sendPasteKeystroke() async -> Bool {
        calls.append("keystroke")
        return keystrokeResult
    }
}

@MainActor
private func makeSimulator(trusted: Bool = true,
                           images: [String: Data] = [:])
    -> (PasteSimulator, FakeDriver, NSPasteboard) {
    let driver = FakeDriver()
    // 命名 pasteboard：测试绝不能污染用户真实剪贴板
    let pb = NSPasteboard(name: .init("toolbox.paste-test.\(UUID().uuidString)"))
    let sim = PasteSimulator(driver: driver, pasteboard: pb,
                             accessibilityTrusted: { trusted },
                             imageLoader: { images[$0] })
    return (sim, driver, pb)
}

private func textItem(_ s: String) -> ClipboardItem {
    ClipboardItem(text: s, sourceBundleID: "com.test", sourceAppName: "Test",
                  at: Date(timeIntervalSince1970: 1))
}

@MainActor @Test func happyPathWritesThenActivatesThenPastes() async {
    let (sim, driver, pb) = makeSimulator()
    let outcome = await sim.paste(textItem("hello"), into: .current)
    #expect(outcome == .pasted)
    // 顺序是硬要求：先写剪贴板再切前台，反了会把旧内容粘出去
    #expect(driver.calls == ["activate", "keystroke"])
    #expect(pb.string(forType: .string) == "hello")
}

@MainActor @Test func missingAccessibilityDegradesButStillCopies() async {
    let (sim, driver, pb) = makeSimulator(trusted: false)
    let outcome = await sim.paste(textItem("secret-ish"), into: nil)
    #expect(outcome == .copiedOnly(.accessibilityNotGranted))
    #expect(driver.calls.isEmpty)                    // 不该去切前台、不该发键
    #expect(pb.string(forType: .string) == "secret-ish")   // 降级 ≠ 失败：内容必须已复制
}

@MainActor @Test func unknownTargetAppDegrades() async {
    let (sim, driver, pb) = makeSimulator()
    #expect(await sim.paste(textItem("x"), into: nil) == .copiedOnly(.targetAppUnknown))
    #expect(driver.calls.isEmpty)
    #expect(pb.string(forType: .string) == "x")
}

@MainActor @Test func activationTimeoutDegrades() async {
    let (sim, driver, _) = makeSimulator()
    driver.activateResult = false
    let item = textItem("y")
    let outcome = await sim.paste(item, into: NSRunningApplication.current)
    #expect(outcome == .copiedOnly(.timedOut))
    #expect(driver.calls == ["activate"])            // 前台没到位就不该发键
}

@MainActor @Test func ownWriteMarkerCarriesItemID() async {
    let (sim, _, pb) = makeSimulator(trusted: false)
    let item = textItem("tagged")
    _ = await sim.paste(item, into: nil)
    #expect(pb.string(forType: .ownWrite) == item.id.uuidString)
}

@MainActor @Test func markerIsClearedOnNextCopySoMonitorResumes() async {
    let (sim, _, pb) = makeSimulator(trusted: false)
    _ = await sim.paste(textItem("a"), into: nil)
    #expect(pb.string(forType: .ownWrite) != nil)
    // 外部 App 复制新内容时 pasteboard 会被整体替换，标记自然消失；
    // 这里模拟那次替换，确认我们的读取端不会把标记当成永久状态
    pb.clearContents()
    pb.setString("from another app", forType: .string)
    #expect(PasteboardSnapshot.read(from: pb).ownWriteMarker == nil)
}

@MainActor @Test func imageItemWritesPNGAndNoString() async {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
    let item = ClipboardItem(imagePNG: png, sha256: "s", pixelSize: CGSize(width: 2, height: 2),
                             sourceBundleID: nil, sourceAppName: nil,
                             at: Date(timeIntervalSince1970: 1))
    let (sim, _, pb) = makeSimulator(trusted: false, images: ["s": png])
    #expect(await sim.paste(item, into: nil) == .copiedOnly(.accessibilityNotGranted))
    #expect(pb.data(forType: .png) == png)
    #expect(pb.string(forType: .string) == nil)
    // 媒体文件丢了（用户手工清了 Media/）必须显式失败，不许写一个空剪贴板
    let (sim2, _, pb2) = makeSimulator(trusted: false)
    pb2.clearContents(); pb2.setString("keepme", forType: .string)
    #expect(await sim2.paste(item, into: nil) == .failed(.imageMissing("s")))
    #expect(pb2.string(forType: .string) == "keepme")
}

@MainActor @Test func fileURLItemWritesURLs() async {
    let (sim, _, pb) = makeSimulator(trusted: false)
    let urls = [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]
    _ = await sim.paste(ClipboardItem(fileURLs: urls, sourceBundleID: nil, sourceAppName: nil,
                                      at: Date(timeIntervalSince1970: 1)), into: nil)
    let read = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    #expect(read.map(\.path) == urls.map(\.path))
}

@MainActor @Test func emptyItemFailsWithoutTouchingPasteboard() async {
    let (sim, driver, pb) = makeSimulator()
    pb.clearContents()
    pb.setString("preexisting", forType: .string)
    let broken = ClipboardItem(kind: .text, text: nil, mediaSHA256: nil, fileURLs: nil,
                               byteLength: 0, pixelSize: nil, sourceBundleID: nil,
                               sourceAppName: nil, createdAt: .init(), lastCopiedAt: .init())
    #expect(await sim.paste(broken, into: nil) == .failed(PasteFailure.emptyItem))
    #expect(pb.string(forType: .string) == "preexisting")   // 不许把用户原有内容清掉
    #expect(driver.calls.isEmpty)
}

// MARK: 粘贴后回写窗口

@MainActor @Test func pasteMarksSelfWriteWindow() async {
    let tracker = SelfWriteTracker()
    let driver = FakeDriver()
    let pb = NSPasteboard(name: .init("toolbox.grace.\(UUID().uuidString)"))
    let sim = PasteSimulator(driver: driver, pasteboard: pb,
                             accessibilityTrusted: { false },
                             imageLoader: { _ in nil }, tracker: tracker)
    #expect(!tracker.isWithinGrace(now: Date()))
    _ = await sim.paste(textItem("x"), into: nil)
    #expect(tracker.isWithinGrace(now: Date()))
    // 窗口过后必须恢复采集，否则用户紧接着的复制会被吞掉
    #expect(!tracker.isWithinGrace(now: Date().addingTimeInterval(SelfWriteTracker.grace + 0.1)))
}

@MainActor @Test func graceWindowShorterThanRealisticCopyInterval() {
    // 宽限期必须明显小于人手动复制的间隔，否则等于漏采
    #expect(SelfWriteTracker.grace <= 1.0)
}

@MainActor @Test func panelIsDismissedBeforePasteKeystroke() async {
    // 回归：面板还开着时它是 key window，合成的 ⌘V 会被投给自己的面板。
    let driver = FakeDriver()
    var panelOpen = true
    driver.panelOpenProbe = { panelOpen }
    let pb = NSPasteboard(name: .init("toolbox.order.\(UUID().uuidString)"))
    let sim = PasteSimulator(driver: driver, pasteboard: pb,
                             accessibilityTrusted: { true }, imageLoader: { _ in nil })
    let outcome = await sim.paste(textItem("x"), into: .current) { panelOpen = false }
    #expect(outcome == .pasted)
    #expect(driver.panelStillOpenAtActivate == false)   // 切前台前面板必须已经关掉
    #expect(driver.calls == ["activate", "keystroke"])
}

@MainActor @Test func prepareNotSuppliedStillWorksButIsUnsafe() async {
    // prepare 是可选参数：不传时行为不变（有测试挡住，免得以后误改成必选）
    let (sim, driver, _) = makeSimulator()
    #expect(await sim.paste(textItem("x"), into: .current) == .pasted)
    #expect(driver.calls == ["activate", "keystroke"])
}
