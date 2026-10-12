import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

@Test func clampedRowsRespectsBounds() {
    #expect(ClipboardPanelGeometry.clampedRows(10) == 10)
    #expect(ClipboardPanelGeometry.clampedRows(0) == ClipboardPanelGeometry.minRows)
    #expect(ClipboardPanelGeometry.clampedRows(-5) == ClipboardPanelGeometry.minRows)
    #expect(ClipboardPanelGeometry.clampedRows(1) == ClipboardPanelGeometry.minRows)
    #expect(ClipboardPanelGeometry.clampedRows(9999) == ClipboardPanelGeometry.maxRows)
}

@Test func panelHeightGrowsLinearlyWithRows() {
    let h = ClipboardPanelGeometry.panelHeight(
        rows: 10, headerHeight: 40, rowHeight: 30, verticalPadding: 14,
        maxAvailable: 2000)
    #expect(h == CGFloat(40 + 10 * 30 + 14))
    let h20 = ClipboardPanelGeometry.panelHeight(
        rows: 20, headerHeight: 40, rowHeight: 30, verticalPadding: 14, maxAvailable: 2000)
    #expect(h20 == CGFloat(40 + 20 * 30 + 14))
    #expect(h20 > h)
}

@Test func panelHeightNeverExceedsAvailableScreen() {
    // 用户设了 40 行但屏幕只放得下 12 行时，必须钳住：
    // 超出屏幕的部分永远滚不到、也点不到
    let h = ClipboardPanelGeometry.panelHeight(
        rows: 40, headerHeight: 40, rowHeight: 30, verticalPadding: 14, maxAvailable: 400)
    #expect(h == CGFloat(400))
}

@Test func panelHeightKeepsAtLeastOneRowVisibleWhenScreenIsTiny() {
    // 可用高度比"头部+一行"还小时，也不能返回 0 或负数（窗口会消失）
    let h = ClipboardPanelGeometry.panelHeight(
        rows: 20, headerHeight: 40, rowHeight: 30, verticalPadding: 14, maxAvailable: 20)
    #expect(h >= CGFloat(40 + 30))
}

@Test func panelHeightIsMonotonicInRows() {
    var last: CGFloat = -1
    for rows in ClipboardPanelGeometry.minRows...ClipboardPanelGeometry.maxRows {
        let h = ClipboardPanelGeometry.panelHeight(
            rows: rows, headerHeight: 40, rowHeight: 30, verticalPadding: 14,
            maxAvailable: 100_000)
        #expect(h > last)
        last = h
    }
}

@Test func defaultRowsIsSaneAndDecodesFromOldFiles() throws {
    // 老用户的 settings.json 里没有这个字段，必须回落默认而不是判为损坏
    let file = URL(fileURLWithPath: "/tmp/toolbox-rows-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let legacy = """
    {"clipboardCapacity":500,"hotkeys":[],"pinMaxZoom":8,"pinMinZoom":0.2,
     "scrollZoomDirection":"upMagnifies"}
    """
    try legacy.data(using: .utf8)!.write(to: file)
    let loaded = try SettingsStore(file: file).load()
    #expect(loaded.clipboardVisibleRows == AppSettings.default.clipboardVisibleRows)
    #expect(loaded.clipboardCapacity == 500)
}

@Test func rowsRoundTripThroughSettings() throws {
    let file = URL(fileURLWithPath: "/tmp/toolbox-rows2-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    var s = AppSettings.default
    s.clipboardVisibleRows = 24
    try SettingsStore(file: file).save(s)
    #expect(try SettingsStore(file: file).load().clipboardVisibleRows == 24)
}
