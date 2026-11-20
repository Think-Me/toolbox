using Toolbox.Core.Capture;
using Xunit;

namespace Toolbox.Core.Tests;

/// <summary>
/// BUG-007 复用判定回归测试：空壳/过时遮罩绝不允许被复用。
/// 实测形态：
///  - 空壳：IsVisible=True 但视觉子元素=0（点击穿透、Esc 无响应）
///  - 拓扑过时：窗口 DIP 尺寸与当前虚拟桌面不符（如按 2560 建窗、屏幕已变 1920）
/// 复用分支（App.xaml.cs `_captureOverlay is { IsLoaded: true } → Activate()`）
/// 一旦激活空壳，截图功能本会话内报废。
/// </summary>
public sealed class OverlayHealthTests
{
    [Theory]
    [InlineData(true, 0, false)]    // 可见但无子元素 = 空壳
    [InlineData(false, 5, false)]   // 有子元素但窗口不可见 = 死窗
    [InlineData(false, 0, false)]    // 全死
    [InlineData(true, 5, true)]     // 可见且有子元素 = 活的
    public void VisualTreeHealth(bool visible, int children, bool expected)
        => Assert.Equal(expected, OverlayHealth.HasLiveVisualTree(visible, children));

    [Fact]
    public void SizeMatchesCurrentDesktop()
    {
        // 完全一致
        Assert.True(OverlayHealth.MatchesCurrentDesktop(1920, 1080, 1920, 1080));
        // DIP 缩放（1.25 缩放下 1920px = 1536 DIP）
        Assert.True(OverlayHealth.MatchesCurrentDesktop(1536, 864, 1536, 864));
        // 拓扑变了：窗口按旧屏建的（2560 宽），屏幕已变 1920 —— 实测空壳的来源
        Assert.False(OverlayHealth.MatchesCurrentDesktop(2560, 1440, 1920, 1080));
        // 分辨率切换 1440↔1920
        Assert.False(OverlayHealth.MatchesCurrentDesktop(1440, 900, 1920, 1080));
        // 容差内（亚像素舍入）
        Assert.True(OverlayHealth.MatchesCurrentDesktop(1920.4, 1079.6, 1920, 1080));
    }

    [Fact]
    public void ZeroDimensionsAreNeverHealthy()
    {
        Assert.False(OverlayHealth.MatchesCurrentDesktop(0, 1080, 1920, 1080));
        Assert.False(OverlayHealth.MatchesCurrentDesktop(1920, 0, 1920, 1080));
        Assert.False(OverlayHealth.MatchesCurrentDesktop(1920, 1080, 0, 1080));
        Assert.False(OverlayHealth.MatchesCurrentDesktop(1920, 1080, 1920, 0));
    }

    [Fact]
    public void ShouldReuseRequiresBothChecks()
    {
        // 视觉树活着但尺寸过时 → 不可复用（拓扑变过）
        Assert.False(OverlayHealth.ShouldReuse(true, 5, 2560, 1440, 1920, 1080));
        // 尺寸匹配但是空壳 → 不可复用
        Assert.False(OverlayHealth.ShouldReuse(true, 0, 1920, 1080, 1920, 1080));
        // 两条全过 → 可复用
        Assert.True(OverlayHealth.ShouldReuse(true, 5, 1920, 1080, 1920, 1080));
    }
}
