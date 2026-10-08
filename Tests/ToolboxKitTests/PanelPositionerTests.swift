import Testing
import Foundation
@testable import ToolboxKit

@Test func clampedInsideScreenEvenAtCorner() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let r = PanelPositioner.rect(width: 400, height: 500, cursor: CGPoint(x: 1500, y: 970),
                                 screenFrame: screen, visibleFrame: screen)
    #expect(r.maxX <= screen.maxX + 0.001)
    #expect(r.maxY <= screen.maxY + 0.001)
    #expect(r.minX >= screen.minX - 0.001)
    #expect(r.minY >= screen.minY - 0.001)
}

@Test func secondaryScreenWithNegativeOriginIsRespected() {
    let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)   // 左副屏
    let r = PanelPositioner.rect(width: 300, height: 200, cursor: CGPoint(x: -100, y: 500),
                                 screenFrame: screen, visibleFrame: screen)
    #expect(r.minX >= screen.minX - 0.001)
    #expect(r.maxX <= screen.maxX + 0.001)
}

@Test func cursorNearTopFlipsPanelBelow() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let top = PanelPositioner.rect(width: 300, height: 200, cursor: CGPoint(x: 500, y: 995),
                                   screenFrame: screen, visibleFrame: screen)
    #expect(top.maxY <= 995.001)                 // 上方放不下 → 翻到光标下方，不许顶出上沿
    let mid = PanelPositioner.rect(width: 300, height: 200, cursor: CGPoint(x: 500, y: 500),
                                   screenFrame: screen, visibleFrame: screen)
    #expect(mid.maxY > 500)                       // 空间够时正常放在光标上方
    #expect(mid.minY >= 500)                      // 且带 gap
}

@Test func menuBarIsRespectedViaVisibleFrame() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 950)      // 顶部 50pt 是菜单栏
    let r = PanelPositioner.rect(width: 300, height: 200, cursor: CGPoint(x: 500, y: 945),
                                 screenFrame: screen, visibleFrame: visible)
    #expect(r.maxY <= visible.maxY + 0.001)
}

@Test func leftEdgeStaysInside() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let r = PanelPositioner.rect(width: 400, height: 200, cursor: CGPoint(x: 5, y: 500),
                                 screenFrame: screen, visibleFrame: screen)
    #expect(r.minX >= screen.minX - 0.001)
}

@Test func bottomEdgeStaysInside() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let r = PanelPositioner.rect(width: 300, height: 400, cursor: CGPoint(x: 500, y: 5),
                                 screenFrame: screen, visibleFrame: screen)
    #expect(r.minY >= screen.minY - 0.001)
    #expect(r.maxY <= screen.maxY + 0.001)
}

@Test func panelTallerThanVisibleAreaIsClampedNotOverflowingTop() {
    // 畸形场景（超高面板 + 超小可视区）：M0 只要求"不得顶出上沿"，
    // 允许下沿越界。真正的压缩高度策略留给 M1（见代码里的 FIXME）。
    let screen = CGRect(x: 0, y: 0, width: 800, height: 300)
    let r = PanelPositioner.rect(width: 300, height: 500, cursor: CGPoint(x: 400, y: 150),
                                 screenFrame: screen, visibleFrame: screen)
    #expect(r.maxY <= screen.maxY + 0.001)
}
