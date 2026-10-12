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

@MainActor
@Test func fontGroupOnlyOccupiesWidthWhenTextToolActive() {
    // 字号组只在文字工具激活时出现。隐藏时必须从行宽里扣掉，
    // 否则其他工具下整行会白宽一截、操作条也跟着偏
    let bar = AnnotationToolbarView()
    let full = bar.idealSize.width
    bar.update(selectedTool: .text, color: AnnotationPalette.defaultColor,
               lineWidth: 4, fontSize: 18, canUndo: false, canRedo: false,
               hasAnnotations: false)
    #expect(bar.visibleWidth == full)
    bar.update(selectedTool: .rect, color: AnnotationPalette.defaultColor,
               lineWidth: 4, fontSize: 18, canUndo: false, canRedo: false,
               hasAnnotations: false)
    #expect(bar.visibleWidth < full)
    #expect(bar.visibleWidth > 0)
    // 切回文字工具要能拿回原宽（扣掉的量必须可逆）
    bar.update(selectedTool: .text, color: AnnotationPalette.defaultColor,
               lineWidth: 4, fontSize: 18, canUndo: false, canRedo: false,
               hasAnnotations: false)
    #expect(bar.visibleWidth == full)
}

@MainActor
@Test func rowUsesVisibleWidthNotIdealWidth() {
    let bar = AnnotationToolbarView()
    let strip = ActionStripView()
    bar.update(selectedTool: .mosaic, color: AnnotationPalette.defaultColor,
               lineWidth: 4, fontSize: 18, canUndo: true, canRedo: false,
               hasAnnotations: true)
    let off = CaptureToolbarLayout.layout(annotationWidth: bar.visibleWidth,
                                          actionWidth: strip.idealSize.width,
                                          selection: CGRect(x: 400, y: 200, width: 300, height: 200),
                                          container: CGRect(x: 0, y: 0, width: 1512, height: 982))
    bar.update(selectedTool: .text, color: AnnotationPalette.defaultColor,
               lineWidth: 4, fontSize: 18, canUndo: true, canRedo: false,
               hasAnnotations: true)
    let on = CaptureToolbarLayout.layout(annotationWidth: bar.visibleWidth,
                                         actionWidth: strip.idealSize.width,
                                         selection: CGRect(x: 400, y: 200, width: 300, height: 200),
                                         container: CGRect(x: 0, y: 0, width: 1512, height: 982))
    #expect(on.annotationBar.width > off.annotationBar.width)
    // 操作条始终紧跟在工具条后面，中间只有一个缝隙
    #expect(on.actionBar.minX - on.annotationBar.maxX == CaptureToolbarLayout.groupGap)
    #expect(off.actionBar.minX - off.annotationBar.maxX == CaptureToolbarLayout.groupGap)
}
