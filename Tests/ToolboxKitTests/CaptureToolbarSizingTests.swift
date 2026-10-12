import AppKit
import Testing
@testable import ToolboxKit

/// 钉住"选完区后按钮全没了"这个 bug 类。
///
/// 起因：`idealSize` 从 `frame.size` 反推，而 `positionStrip` 在没有选区时
/// 会把 frame 清成 .zero —— 于是按钮的固有宽度被永久清零，面板变成
/// "可见但零宽"，屏幕上什么都看不到，日志里 hidden 却全是 false。
@MainActor
@Test func actionStripIdealSizeSurvivesFrameReset() {
    let strip = ActionStripView()
    let before = strip.idealSize
    #expect(before.width > 100)
    strip.frame = .zero
    #expect(strip.idealSize == before)
    strip.frame = CGRect(x: 10, y: 20, width: 1, height: 1)
    #expect(strip.idealSize == before)
}

@MainActor
@Test func annotationToolbarIdealSizeSurvivesFrameReset() {
    let bar = AnnotationToolbarView()
    let before = bar.idealSize
    // 5 工具 + 6 色 + 3 线宽 + 撤销重做清空，必然比操作条宽
    #expect(before.width > 300)
    #expect(before.height == CaptureToolbarLayout.rowHeight)
    bar.frame = .zero
    #expect(bar.idealSize == before)
}

@MainActor
@Test func bothBarsFitTheRowHeight() {
    let strip = ActionStripView()
    let bar = AnnotationToolbarView()
    #expect(strip.idealSize.height == CaptureToolbarLayout.rowHeight)
    #expect(bar.idealSize.height == CaptureToolbarLayout.rowHeight)
}

@MainActor
@Test func layoutWithRealWidthsProducesNonZeroFrames() {
    let strip = ActionStripView()
    let bar = AnnotationToolbarView()
    let row = CaptureToolbarLayout.layout(annotationWidth: bar.idealSize.width,
                                          actionWidth: strip.idealSize.width,
                                          selection: CGRect(x: 400, y: 200, width: 300, height: 200),
                                          container: CGRect(x: 0, y: 0, width: 1512, height: 982))
    #expect(row.annotationBar.width == bar.idealSize.width)
    #expect(row.actionBar.width == strip.idealSize.width)
    #expect(row.annotationBar.width > 0 && row.actionBar.width > 0)
    #expect(row.annotationBar.minY == row.actionBar.minY)
}
