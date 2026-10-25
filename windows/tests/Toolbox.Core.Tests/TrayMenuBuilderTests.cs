using Toolbox.Core.Settings;
using Toolbox.Core.Shell;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class TrayMenuBuilderTests
{
    private static IReadOnlyList<TrayMenuItem> Build(
        bool recording = true, bool loginItemEnabled = false, TrayHostsSnapshot? hosts = null) =>
        TrayMenuBuilder.Items(new AppSettings(), recording, loginItemEnabled, hosts ?? TrayHostsSnapshot.Empty);

    [Fact]
    public void TopLevelOrderAndSeparatorsMatchTheContract()
    {
        var items = Build();

        Assert.Collection(items,
            i => Assert.Equal(TrayAction.Clipboard, i.Action),
            i => Assert.Equal(TrayAction.HostsPanel, i.Action),
            i => Assert.Equal(TrayAction.CaptureRegion, i.Action),
            i => Assert.Equal(TrayAction.CaptureFull, i.Action),
            i => Assert.Equal(TrayAction.KillAllPins, i.Action),
            i => Assert.Equal(TrayAction.Translate, i.Action),
            i => Assert.True(i.IsSeparator),
            i => Assert.Equal(TrayAction.TogglePause, i.Action),
            i => Assert.Equal(TrayAction.OpenSettings, i.Action),
            i => Assert.Equal(TrayAction.ToggleLoginItem, i.Action),
            i => Assert.True(i.IsSeparator),
            i => Assert.Equal(TrayAction.Quit, i.Action));
    }

    /// <summary>"暂停记录"在暂停时才打勾 —— 勾选表示"当前已暂停"，与 Mac 版一致。</summary>
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void PauseItemIsCheckedOnlyWhilePaused(bool recording, bool expected)
    {
        var pause = Build(recording: recording).Single(i => i.Action == TrayAction.TogglePause);
        Assert.Equal(expected, pause.IsChecked);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void LoginItemCheckFollowsState(bool enabled)
    {
        var item = Build(loginItemEnabled: enabled).Single(i => i.Action == TrayAction.ToggleLoginItem);
        Assert.Equal(enabled, item.IsChecked);
    }

    [Fact]
    public void ShortcutTextComesFromTheSettings()
    {
        var clipboard = Build().Single(i => i.Action == TrayAction.Clipboard);
        Assert.Equal("Ctrl+Alt+V", clipboard.Shortcut);
    }

    [Fact]
    public void MissingHotkeyShowsNoShortcut()
    {
        var settings = new AppSettings { Hotkeys = { ClipboardPanel = default } };
        var items = TrayMenuBuilder.Items(settings, true, false, TrayHostsSnapshot.Empty);

        Assert.Null(items.Single(i => i.Action == TrayAction.Clipboard).Shortcut);
    }

    [Fact]
    public void HostsSubmenuStartsWithTheManagementSwitch()
    {
        var hosts = Build().Single(i => i.Action == TrayAction.HostsPanel);
        var first = hosts.Children[0];

        Assert.Equal(TrayAction.HostsManagementToggle, first.Action);
        Assert.True(first.IsChecked);
        Assert.Equal("Hosts 托管：开", first.Title);
    }

    [Fact]
    public void HostsSubmenuCollapsesToTheSwitchWhenManagementIsOff()
    {
        var item = Build(hosts: new TrayHostsSnapshot(false, [])).Single(i => i.Action == TrayAction.HostsPanel);

        Assert.Single(item.Children);
        Assert.Equal("Hosts 托管：关", item.Children[0].Title);
        Assert.False(item.Children[0].IsChecked);
    }

    [Fact]
    public void HostsSubmenuExplainsHowToAddTheFirstRule()
    {
        var item = Build().Single(i => i.Action == TrayAction.HostsPanel);
        var placeholder = Assert.Single(item.Children.Skip(1));

        Assert.False(placeholder.IsEnabled);
        Assert.Contains("还没有规则", placeholder.Title);
    }

    [Fact]
    public void HostsSubmenuSeparatesGroupsAndCarriesRuleIds()
    {
        var id1 = Guid.NewGuid();
        var id2 = Guid.NewGuid();
        var snapshot = new TrayHostsSnapshot(true,
        [
            new TrayHostsRow(id1, "公司", "内网", true),
            new TrayHostsRow(id2, "个人", "博客", false),
        ]);

        var children = Build(hosts: snapshot).Single(i => i.Action == TrayAction.HostsPanel).Children;

        Assert.Equal(4, children.Count);          // 总开关 + 规则1 + 分隔线 + 规则2
        Assert.True(children[2].IsSeparator);
        Assert.Equal(id1, children[1].RuleId);
        Assert.True(children[1].IsChecked);
        Assert.Equal(id2, children[3].RuleId);
        Assert.False(children[3].IsChecked);
    }

    /// <summary>空子菜单在 Win32 里画不出来，任何状态下都必须至少有一行。</summary>
    [Theory]
    [InlineData(true, 0)]
    [InlineData(true, 2)]
    [InlineData(false, 0)]
    public void HostsSubmenuIsNeverEmpty(bool managementOn, int ruleCount)
    {
        var rows = Enumerable.Range(0, ruleCount)
            .Select(i => new TrayHostsRow(Guid.NewGuid(), "组", "规则" + i, true))
            .ToArray();
        var children = Build(hosts: new TrayHostsSnapshot(managementOn, rows))
            .Single(i => i.Action == TrayAction.HostsPanel).Children;

        Assert.NotEmpty(children);
    }
}
