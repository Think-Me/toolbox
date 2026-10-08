import Carbon.HIToolbox
import Testing
@testable import ToolboxKit

@Test func emptyListHasNoValidSelection() {
    var s = ClipboardListSelection(count: 0)
    #expect(!s.isValid)
    s.move(-1); s.move(1)
    #expect(s.index == 0)
}

@Test func moveWrapsBothDirections() {
    var s = ClipboardListSelection(count: 5)
    s.select(0)
    s.move(-1)
    #expect(s.index == 4)          // 顶部再往上 → 绕到底部
    s.move(1)
    #expect(s.index == 0)          // 底部再往下 → 绕回顶部
}

@Test func moveByMultipleStaysInRange() {
    var s = ClipboardListSelection(count: 5)
    s.select(3)
    s.move(10)
    #expect((0..<5).contains(s.index))
    s.move(-99)
    #expect((0..<5).contains(s.index))
}

@Test func shrinkingListClampsIndex() {
    var s = ClipboardListSelection(count: 10)
    s.select(8)
    s.setCount(3)
    #expect(s.index == 2)
    s.setCount(0)
    #expect(s.index == 0)
    #expect(!s.isValid)
}

@Test func growingListKeepsIndex() {
    var s = ClipboardListSelection(count: 3)
    s.select(2)
    s.setCount(20)
    #expect(s.index == 2)
}

@Test func quickPickMapsOneThroughNineToRows() {
    let s = ClipboardListSelection(count: 20)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_1)) == 0)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_9)) == 8)
    // ⌘0 不是"第 10 行"，避免用户以为能选到没高亮的东西
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_0)) == nil)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_A)) == nil)
}

@Test func quickPickRejectsRowsBeyondCurrentList() {
    let s = ClipboardListSelection(count: 2)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_1)) == 0)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_2)) == 1)
    #expect(s.quickPick(keyCode: UInt16(kVK_ANSI_3)) == nil)   // 只有 2 行
}

@Test func filteringResetsToTop() {
    // 搜索后行集会变，旧 index 可能指向完全不同的条目，必须回 0
    var s = ClipboardListSelection(count: 20)
    s.select(15)
    s.applyFilter(count: 4)
    #expect(s.index == 0)
    #expect(s.count == 4)
}

@Test func emptyFilterResultIsNotValid() {
    var s = ClipboardListSelection(count: 5)
    s.applyFilter(count: 0)
    #expect(!s.isValid)
}

@Test func currentItemOnlyWhenValid() {
    let items = (1...3).map { ClipboardItem(text: "i\($0)", sourceBundleID: nil,
                                            sourceAppName: nil,
                                            at: Date(timeIntervalSince1970: Double($0))) }
    var s = ClipboardListSelection(count: items.count)
    s.select(1)
    #expect(s.current(in: items)?.text == "i2")
    s.setCount(0)
    #expect(s.current(in: items) == nil)
}
