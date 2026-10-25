using System.Runtime.InteropServices;
using Toolbox.App.Shell;
using Toolbox.Core.Capture;

namespace Toolbox.App.Capture;

/// <summary>
/// 可见顶层窗口候选（对齐 macOS WindowCandidateProvider 的职责）：
/// 给选区吸附提供"线"，给智能选窗提供"点击命中目标"。
/// 排除规则：不可见/最小化/零尺寸/工具窗（含我们自己的托盘消息窗）/被 cloaked 的
/// UWP 幽灵窗口/自己进程的窗口（遮罩窗本身不能成为候选）。
/// </summary>
internal static class WindowCandidates
{
    public static List<NativeMethods.Rect2> VisibleTopLevelRects()
    {
        var rects = new List<NativeMethods.Rect2>();
        var selfPid = (uint)Environment.ProcessId;

        NativeMethods.EnumWindows((window, _) =>
        {
            if (!NativeMethods.IsWindowVisible(window) || NativeMethods.IsIconic(window)) return true;
            if (NativeMethods.GetWindowRect(window, out var rect) && rect.Right <= rect.Left) return true;

            var exStyle = NativeMethods.GetWindowLongPtr(window, NativeMethods.GwlExStyle);
            if ((exStyle & NativeMethods.WsExToolWindow) != 0) return true;
            if (NativeMethods.DwmGetWindowAttribute(window, NativeMethods.DwmwaCloaked, out var cloaked, 4) == 0 &&
                cloaked != 0) return true;
            if (NativeMethods.GetWindowThreadProcessId(window, out var pid) != 0 && pid == selfPid) return true;
            // 无标题小窗多半是系统托盘类杂物；有标题才当候选
            if (NativeMethods.GetWindowTextLength(window) == 0) return true;

            rects.Add(rect);
            return true;
        }, IntPtr.Zero);

        // EnumWindows 返回顺序即 Z 序（从前到后），保持它：智能选窗要取第一个命中的
        return rects;
    }

    /// <summary>屏幕像素矩形 -> 遮罩视图 DIP 矩形。</summary>
    public static List<SnapRect> ToOverlayDip(IEnumerable<NativeMethods.Rect2> rects,
                                              NativeMethods.Rect2 monitor, double scale) =>
        rects.Select(r => new SnapRect(
                (r.Left - monitor.Left) / scale,
                (r.Top - monitor.Top) / scale,
                (r.Right - r.Left) / scale,
                (r.Bottom - r.Top) / scale))
            .ToList();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}
