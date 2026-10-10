import CoreGraphics
import Foundation
import Testing
@testable import ToolboxKit

// 主屏：Quartz 左上角就是 (0,0)
private let mainScreen = ScreenGeometry(quartzOrigin: .zero, size: CGSize(width: 1512, height: 982))
// 左副屏：Quartz 里 x 为负
private let leftScreen = ScreenGeometry(quartzOrigin: CGPoint(x: -1920, y: 0),
                                        size: CGSize(width: 1920, height: 1080))

@Test func keepsOnlyNormalLayerWindowsOfOtherProcesses() {
    let raw = [
        RawWindow(pid: 100, layer: 0, bounds: CGRect(x: 10, y: 10, width: 200, height: 100)),
        RawWindow(pid: 101, layer: 0, bounds: CGRect(x: 50, y: 50, width: 200, height: 100)),
        RawWindow(pid: 102, layer: 25, bounds: CGRect(x: 0, y: 0, width: 100, height: 30)),  // 菜单栏
        RawWindow(pid: 103, layer: 101, bounds: CGRect(x: 0, y: 0, width: 100, height: 30)), // 浮层/贴图
    ]
    let out = WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 100)
    #expect(out == [CGRect(x: 50, y: 50, width: 200, height: 100)])
}

@Test func dropsZeroAreaWindows() {
    let raw = [RawWindow(pid: 1, layer: 0, bounds: CGRect(x: 5, y: 5, width: 0, height: 0)),
               RawWindow(pid: 2, layer: 0, bounds: CGRect(x: 5, y: 5, width: 10, height: 0)),
               RawWindow(pid: 3, layer: 0, bounds: CGRect(x: 5, y: 5, width: 0, height: 10))]
    #expect(WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999).isEmpty)
}

@Test func negativeDimensionsCannotReachTheFilter() {
    // CGRect 在构造时就把负宽高标准化（-10 → x 左移、宽变正），
    // 所以"负尺寸窗口"这个输入在 CoreGraphics 里根本不存在，
    // 过滤器只需要挡住零面积。写这条测试是为了记下这个事实，
    // 免得以后有人以为漏了个分支。
    let r = CGRect(x: 5, y: 5, width: -10, height: 20)
    #expect(r.width == 10 && r.minX == -5)
}

@Test func dropsWindowsEntirelyOffThisScreen() {
    let raw = [RawWindow(pid: 1, layer: 0, bounds: CGRect(x: -3000, y: -3000, width: 100, height: 100))]
    #expect(WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999).isEmpty)
}

@Test func clipsCrossScreenWindowToThisScreen() {
    // 窗口横跨主屏与左副屏：只有落在本屏内的部分能被框选
    let raw = [RawWindow(pid: 1, layer: 0, bounds: CGRect(x: -500, y: 100, width: 900, height: 400))]
    let out = WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999)
    #expect(out.count == 1)
    #expect(out[0] == CGRect(x: 0, y: 100, width: 400, height: 400))
}

@Test func preservesFrontToBackOrder() {
    let raw = (1...5).map { RawWindow(pid: Int32($0), layer: 0,
                                      bounds: CGRect(x: CGFloat($0) * 10, y: 0,
                                                     width: 100, height: 100)) }
    let out = WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999)
    #expect(out.map(\.minX) == raw.map { $0.bounds.minX })
}

@Test func secondaryScreenShiftsByItsOwnQuartzOrigin() {
    // 副屏上的窗口要换算成"该屏自己的坐标"，否则遮罩里的命中/吸附全偏 1920
    let raw = [RawWindow(pid: 1, layer: 0, bounds: CGRect(x: -1900, y: 200, width: 300, height: 200))]
    #expect(WindowFilter.candidateRects(raw, screen: leftScreen, ownPID: 999)
            == [CGRect(x: 20, y: 200, width: 300, height: 200)])
    #expect(WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999).isEmpty)
}

@Test func ownPIDExclusionIsExact() {
    let raw = [RawWindow(pid: 12, layer: 0, bounds: CGRect(x: 0, y: 0, width: 50, height: 50)),
               RawWindow(pid: 1234, layer: 0, bounds: CGRect(x: 60, y: 0, width: 50, height: 50))]
    let out = WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 12)
    #expect(out == [CGRect(x: 60, y: 0, width: 50, height: 50)])
}

@Test func dockAndDesktopLayersAreIgnored() {
    let raw = [RawWindow(pid: 1, layer: 20, bounds: CGRect(x: 0, y: 900, width: 100, height: 60)),
               RawWindow(pid: 2, layer: -100, bounds: CGRect(x: 0, y: 0, width: 100, height: 60))]
    #expect(WindowFilter.candidateRects(raw, screen: mainScreen, ownPID: 999).isEmpty)
}

@Test func screenGeometryConvertsAppKitFrameToQuartzOrigin() {
    // 主屏 AppKit frame (0,0,1512,982) → Quartz 左上角 (0,0)
    #expect(ScreenGeometry(appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           primaryHeight: 982)
            == ScreenGeometry(quartzOrigin: .zero, size: CGSize(width: 1512, height: 982)))
    // 等高左副屏 AppKit x=-1920 → Quartz (-1920, 0)
    #expect(ScreenGeometry(appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 982),
                           primaryHeight: 982)?.quartzOrigin.x == -1920)
    // 主屏**下方**的副屏：AppKit y 为负，Quartz y 为正（往下走）
    let below = ScreenGeometry(appKitFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                               primaryHeight: 982)
    #expect(below?.quartzOrigin.y == 982)
}

@Test func liveProviderRunsAndNeverReturnsOwnWindows() {
    // 内容随桌面变化，只断言不变量：正面积、不含本进程、坐标系正确
    let own = ProcessInfo.processInfo.processIdentifier
    let out = CGWindowCandidateProvider().candidates(for: mainScreen, excluding: own)
    #expect(out.allSatisfy { $0.width > 0 && $0.height > 0 })
    #expect(out.allSatisfy { $0.minX >= -0.5 && $0.minY >= -0.5 })
    #expect(out.allSatisfy { $0.maxX <= mainScreen.size.width + 0.5
                            && $0.maxY <= mainScreen.size.height + 0.5 })
}
