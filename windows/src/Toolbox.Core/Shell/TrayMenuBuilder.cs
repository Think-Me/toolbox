using Toolbox.Core.Settings;

namespace Toolbox.Core.Shell;

/// <summary>
/// 托盘的菜单契约。和 Mac 版 MenuBuilder 同构：动作表与热键回调共用同一份实现，
/// 否则"从菜单点"和"按热键"会走两条路径，行为迟早分叉。
/// </summary>
public static class TrayMenuBuilder
{
    /// <summary>每次打开都重建（不缓存），否则暂停/自启的勾选状态会停在旧值。</summary>
    public static IReadOnlyList<TrayMenuItem> Items(AppSettings settings, bool recording,
                                                   bool loginItemEnabled, TrayHostsSnapshot hosts)
    {
        var hotkeys = HotkeyRegistrationTable.From(settings.Hotkeys);
        return
        [
            HotkeyItem("剪贴板历史", HotkeyId.ClipboardPanel, hotkeys, TrayAction.Clipboard),
            new TrayMenuItem
            {
                Title = "Hosts 规则",
                Shortcut = ShortcutOf(hotkeys, HotkeyId.HostsPanel),
                Action = TrayAction.HostsPanel,
                Children = HostsSubmenu(hosts),
            },
            HotkeyItem("区域截图", HotkeyId.Screenshot, hotkeys, TrayAction.CaptureRegion),
            HotkeyItem("翻译选中文本", HotkeyId.Translation, hotkeys, TrayAction.Translate),
            TrayMenuItem.Separator,
            new TrayMenuItem { Title = "暂停剪贴板记录", IsChecked = !recording, Action = TrayAction.TogglePause },
            new TrayMenuItem { Title = "设置与快捷键…", Action = TrayAction.OpenSettings },
            new TrayMenuItem { Title = "登录时启动", IsChecked = loginItemEnabled, Action = TrayAction.ToggleLoginItem },
            TrayMenuItem.Separator,
            new TrayMenuItem { Title = "退出 Toolbox", Action = TrayAction.Quit },
        ];
    }

    /// <summary>子菜单：总开关 + 每条规则一行（勾选即切换）。**永远不为空** —— 空子菜单在 Win32 里画不出来。</summary>
    private static IReadOnlyList<TrayMenuItem> HostsSubmenu(TrayHostsSnapshot hosts)
    {
        var children = new List<TrayMenuItem>
        {
            new()
            {
                Title = hosts.ManagementOn ? "Hosts 托管：开" : "Hosts 托管：关",
                IsChecked = hosts.ManagementOn,
                Action = TrayAction.HostsManagementToggle,
            },
        };
        if (!hosts.ManagementOn) return children;

        if (hosts.Rows.Count == 0)
        {
            children.Add(new TrayMenuItem
            {
                Title = "（还没有规则，去设置里新建）",
                IsEnabled = false,
            });
            return children;
        }

        string? lastGroup = null;
        foreach (var row in hosts.Rows)
        {
            if (lastGroup is not null && row.Group != lastGroup) children.Add(TrayMenuItem.Separator);
            lastGroup = row.Group;
            children.Add(new TrayMenuItem
            {
                Title = row.Name,
                IsChecked = row.Enabled,
                Action = TrayAction.HostsRuleToggle,
                RuleId = row.Id,
            });
        }
        return children;
    }

    private static TrayMenuItem HotkeyItem(string title, HotkeyId id,
                                           HotkeyRegistrationTable hotkeys, TrayAction action) =>
        new() { Title = title, Shortcut = ShortcutOf(hotkeys, id), Action = action };

    private static string? ShortcutOf(HotkeyRegistrationTable hotkeys, HotkeyId id) =>
        hotkeys.Get(id) is { IsEmpty: false } gesture ? gesture.ToString() : null;
}
