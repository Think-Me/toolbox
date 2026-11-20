namespace Toolbox.Core.Capture;

/// <summary>
/// 截图遮罩的复用判定（BUG-007 的核心纯逻辑）。
///
/// 背景：遮罩窗口在分辨率/显示拓扑变化后可能变成「空壳」——HWND 还在、可见，
/// 但视觉树已死（无内容、鼠标点击穿透、Esc 无响应）。此时 App.xaml.cs 的
/// `_captureOverlay is { IsLoaded: true } → Activate()` 复用分支会永远激活这个空壳，
/// 截图功能在本次会话内报废（用户表现为「按了热键什么都没有」）。
///
/// 复用前必须回答两个问题（对应两个判定）：
/// 1. 窗口还有内容吗（视觉树活着吗）？
/// 2. 窗口的 DIP 尺寸还和当前虚拟桌面匹配吗（拓扑没变过吗）？
/// 任何一关不过 = 空壳/过时遮罩，必须关掉重建（而不是 Activate 一个死窗口）。
/// </summary>
public static class OverlayHealth
{
    /// <summary>
    /// 视觉树健康判定：遮罩构造时会挂上压暗层等一批视觉子元素，
    /// 空壳的特征是它们全没了。hasVisualChildren 只有在两条都满足时才算健康：
    /// 窗口可见、且能枚举到子元素。
    /// </summary>
    public static bool HasLiveVisualTree(bool isWindowVisible, int visualChildCount) =>
        isWindowVisible && visualChildCount > 0;

    /// <summary>
    /// 尺寸匹配判定：遮罩按创建时的虚拟桌面尺寸（DIP）建窗；分辨率/拓扑变化后
    /// 屏幕的 DIP 尺寸变了，旧遮罩要么盖不满（留黑边）要么超界（错位+畸形窗口，
    /// 实测见 rect=(-7,-7,2567,1447) 这种 2574 宽的怪物）。尺寸不再匹配就该重建。
    /// </summary>
    public static bool MatchesCurrentDesktop(double windowWidth, double windowHeight,
                                             double desktopWidth, double desktopHeight,
                                             double tolerance = 1.0)
    {
        if (windowWidth <= 0 || windowHeight <= 0) return false;
        if (desktopWidth <= 0 || desktopHeight <= 0) return false;
        return Math.Abs(windowWidth - desktopWidth) <= tolerance &&
               Math.Abs(windowHeight - desktopHeight) <= tolerance;
    }

    /// <summary>组合判定：两条全过才允许复用。</summary>
    public static bool ShouldReuse(bool isWindowVisible, int visualChildCount,
                                   double windowWidth, double windowHeight,
                                   double desktopWidth, double desktopHeight,
                                   double tolerance = 1.0) =>
        HasLiveVisualTree(isWindowVisible, visualChildCount) &&
        MatchesCurrentDesktop(windowWidth, windowHeight, desktopWidth, desktopHeight, tolerance);
}
