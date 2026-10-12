import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

@Test func annotationCodableRoundTrip() throws {
    let a = Annotation(tool: .rect,
                       points: [CGPoint(x: 10, y: 20), CGPoint(x: 300, y: 220)],
                       color: AnnotationPalette.colors[2],
                       lineWidth: 4)
    let data = try JSONEncoder().encode(a)
    let back = try JSONDecoder().decode(Annotation.self, from: data)
    #expect(back == a)
    #expect(back.points.count == 2)
    #expect(back.color == AnnotationPalette.colors[2])
}

@Test func annotationWithTextRoundTrips() throws {
    let a = Annotation(tool: .text, points: [CGPoint(x: 5, y: 5)],
                       color: .pureRed, lineWidth: 2,
                       text: "中文标注 with symbols ✓", fontSize: 18)
    let back = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a))
    #expect(back.text == "中文标注 with symbols ✓")
    #expect(back.fontSize == 18)
}

@Test func equalityIsStructuralNotIdentity() {
    // 撤销栈靠"整份列表是否相等"决定要不要压一步，
    // 若只比 id，改颜色/改点都会被当成没变化
    let base = Annotation(tool: .pen, points: [.zero, CGPoint(x: 1, y: 1)],
                          color: .pureRed, lineWidth: 2)
    var moved = base
    moved.points = [.zero, CGPoint(x: 9, y: 9)]
    #expect(moved != base)

    var recolored = base
    recolored.color = .pureBlue
    #expect(recolored != base)

    var widened = base
    widened.lineWidth = 8
    #expect(widened != base)
    #expect(base == base)
}

@Test func toolRawValuesAreStable() {
    // 这些串会写进用户的撤销栈/未来的持久化，改了就读不出旧数据
    #expect(AnnotationTool.rect.rawValue == "rect")
    #expect(AnnotationTool.arrow.rawValue == "arrow")
    #expect(AnnotationTool.pen.rawValue == "pen")
    #expect(AnnotationTool.mosaic.rawValue == "mosaic")
    #expect(AnnotationTool.text.rawValue == "text")
    #expect(AnnotationTool.allCases.count == 5)
}

@Test func colorComponentsAreClamped() {
    let c = AnnotationColor(red: 2, green: -1, blue: 0.5, opacity: 5)
    #expect(c.red == 1 && c.green == 0 && c.blue == 0.5 && c.opacity == 1)
}

@Test func colorConvertsToNSColor() {
    let ns = AnnotationColor(red: 1, green: 0, blue: 0, opacity: 0.5).nsColor
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ns.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    #expect(abs(r - 1) < 0.001 && abs(g) < 0.001 && abs(b) < 0.001)
    #expect(abs(a - 0.5) < 0.001)
}

@Test func paletteIsFixedAndStable() {
    // UI 直接按这个顺序排布圆点，顺序变了用户会觉得"颜色被换过"
    #expect(AnnotationPalette.colors.count == 6)
    #expect(AnnotationPalette.lineWidths.count == 3)
    #expect(AnnotationPalette.lineWidths.first! < AnnotationPalette.lineWidths.last!)
    #expect(Set(AnnotationPalette.colors.map(\.hexString)).count == 6)   // 无重复
}

@Test func paletteColorsAreTheExpectedOnes() {
    let hexes = AnnotationPalette.colors.map(\.hexString)
    #expect(hexes.contains("#FF3B30"))   // 红
    #expect(hexes.contains("#FFCC00"))   // 黄
    #expect(hexes.contains("#34C759"))   // 绿
    #expect(hexes.contains("#007AFF"))   // 蓝
    #expect(hexes.contains("#FFFFFF"))   // 白
    #expect(hexes.contains("#1C1C1E"))   // 近黑
}

@Test func defaultSelectionsAreSensible() {
    #expect(AnnotationPalette.defaultColor == AnnotationPalette.colors[0])
    #expect(AnnotationPalette.lineWidths.contains(AnnotationPalette.defaultLineWidth))
}

@Test func boundingBoxCoversAllPoints() {
    let a = Annotation(tool: .pen,
                       points: [CGPoint(x: 100, y: 50), CGPoint(x: 20, y: 300),
                                CGPoint(x: 400, y: 10)],
                       color: .pureRed, lineWidth: 4)
    #expect(a.boundingBox == CGRect(x: 20, y: 10, width: 380, height: 290))
}

@Test func boundingBoxHandlesDegenerateInput() {
    #expect(Annotation(tool: .rect, points: [], color: .pureRed, lineWidth: 2).boundingBox == .zero)
    let single = Annotation(tool: .text, points: [CGPoint(x: 7, y: 9)],
                            color: .pureRed, lineWidth: 2)
    #expect(single.boundingBox == CGRect(x: 7, y: 9, width: 0, height: 0))
}

@Test func isCompleteRequiresEnoughPoints() {
    // 画笔只有 1 个点不该进撤销栈（用户手抖碰了一下不该产生一步可撤销的操作）
    #expect(Annotation(tool: .pen, points: [.zero], color: .pureRed, lineWidth: 2).isComplete == false)
    #expect(Annotation(tool: .rect, points: [.zero, CGPoint(x: 1, y: 1)],
                       color: .pureRed, lineWidth: 2).isComplete == true)
    // 文字没有内容也不算完成
    #expect(Annotation(tool: .text, points: [.zero], color: .pureRed, lineWidth: 2,
                       text: "").isComplete == false)
    #expect(Annotation(tool: .text, points: [.zero], color: .pureRed, lineWidth: 2,
                       text: "hi").isComplete == true)
}

@Test func hexStringMatchesColor() {
    #expect(AnnotationColor(red: 1, green: 0, blue: 0, opacity: 1).hexString == "#FF0000")
    #expect(AnnotationColor(red: 0, green: 0, blue: 0, opacity: 1).hexString == "#000000")
}

// MARK: 设置值 → 调色板

@Test func nearestColorMatchesPaletteByHex() {
    for c in AnnotationPalette.colors {
        #expect(AnnotationPalette.nearestColor(hex: c.hexString) == c)
    }
}

@Test func nearestColorFallsBackForGarbageOrMissing() {
    // 用户手改过 settings.json、或调色板换过版本时，
    // 不能出现"工具条里没有任何颜色被选中"的状态
    #expect(AnnotationPalette.nearestColor(hex: "#123456") == AnnotationPalette.defaultColor)
    #expect(AnnotationPalette.nearestColor(hex: "") == AnnotationPalette.defaultColor)
    #expect(AnnotationPalette.nearestColor(hex: "red") == AnnotationPalette.defaultColor)
}

@Test func nearestLineWidthSnapsToStridedValues() {
    #expect(AnnotationPalette.nearestLineWidth(5) == 4)
    #expect(AnnotationPalette.nearestLineWidth(7) == 8)
    #expect(AnnotationPalette.nearestLineWidth(2) == 2)
    #expect(AnnotationPalette.nearestLineWidth(0) == 2)     // 0 会让线画不出来
    #expect(AnnotationPalette.nearestLineWidth(999) == 8)
}

@Test func paletteColorNamesAlignWithColors() {
    #expect(AnnotationPalette.colorNames.count == AnnotationPalette.colors.count)
}
