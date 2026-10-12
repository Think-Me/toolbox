import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func annotationBarAndActionStripShareOneRow() {
    // 用户明确要求：工具条和操作条**同一行**
    let sel = CGRect(x: 400, y: 200, width: 300, height: 200)
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    #expect(out.annotationBar.maxY == out.actionBar.maxY)
    #expect(out.annotationBar.minY == out.actionBar.minY)
    #expect(out.annotationBar.height == out.actionBar.height)
    #expect(out.annotationBar.height == CaptureToolbarLayout.rowHeight)
}

@Test func actionBarSitsRightAfterAnnotationBarWithOneGap() {
    let sel = CGRect(x: 400, y: 200, width: 300, height: 200)
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    #expect(out.actionBar.minX - out.annotationBar.maxX == CaptureToolbarLayout.groupGap)
}

@Test func rowIsCenteredOnTheSelection() {
    let sel = CGRect(x: 400, y: 200, width: 300, height: 200)
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    let rowMinX = out.annotationBar.minX
    let rowMaxX = out.actionBar.maxX
    #expect(abs((rowMinX + rowMaxX) / 2 - sel.midX) <= 1)
}

@Test func rowGoesAboveWhenNoRoomBelow() {
    let sel = CGRect(x: 400, y: 700, width: 300, height: 180)   // 底部只剩 20pt
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    #expect(out.annotationBar.maxY <= sel.minY)
}

@Test func wholeRowStaysInsideContainer() {
    // 选区贴右边缘时，整行（而不只是操作条）必须被推回屏内
    let sel = CGRect(x: 1200, y: 100, width: 230, height: 200)
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    #expect(out.annotationBar.minX >= screen.minX)
    #expect(out.actionBar.maxX <= screen.maxX)
}

@Test func tinySelectionStillGetsTheWholeRowInsideScreen() {
    let sel = CGRect(x: 5, y: 5, width: 40, height: 30)
    let out = CaptureToolbarLayout.layout(annotationWidth: 360, actionWidth: 180,
                                          selection: sel, container: screen)
    #expect(out.annotationBar.minX >= 0)
    #expect(out.actionBar.maxX <= screen.maxX)
    #expect(out.annotationBar.width == 360)
    #expect(out.actionBar.width == 180)
}

@Test func layoutIsStableForEqualInputs() {
    let a = CaptureToolbarLayout.layout(annotationWidth: 300, actionWidth: 150,
                                        selection: CGRect(x: 100, y: 100, width: 200, height: 100),
                                        container: screen)
    let b = CaptureToolbarLayout.layout(annotationWidth: 300, actionWidth: 150,
                                        selection: CGRect(x: 100, y: 100, width: 200, height: 100),
                                        container: screen)
    #expect(a == b)
}
