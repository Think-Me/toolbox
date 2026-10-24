namespace Toolbox.Core.Shell;

/// <summary>菜单项要执行的动作。渲染层按 Action 建 id→动作的映射，不按标题匹配。</summary>
public enum TrayAction
{
    None,
    Clipboard,
    HostsPanel,
    CaptureRegion,
    Translate,
    TogglePause,
    OpenSettings,
    ToggleLoginItem,
    HostsManagementToggle,
    HostsRuleToggle,
    Quit,
}

/// <summary>
/// 菜单项的纯数据描述。托盘渲染层只负责把它变成 HMENU，结构本身可单测，
/// 这样"菜单契约"能被测试锁住，而不是靠手工点。
/// </summary>
public sealed record TrayMenuItem
{
    public string Title { get; init; } = "";

    /// <summary>右侧显示的快捷键文本，例如 "Ctrl+Alt+V"。没有键位时为 null。</summary>
    public string? Shortcut { get; init; }

    public bool IsSeparator { get; init; }
    public bool IsChecked { get; init; }
    public bool IsEnabled { get; init; } = true;
    public TrayAction Action { get; init; } = TrayAction.None;

    /// <summary>Hosts 规则行的 id，HostsRuleToggle 用。</summary>
    public Guid? RuleId { get; init; }

    public IReadOnlyList<TrayMenuItem> Children { get; init; } = [];

    public bool HasChildren => Children.Count > 0;

    public static TrayMenuItem Separator { get; } = new() { IsSeparator = true, IsEnabled = false };
}

public sealed record TrayHostsRow(Guid Id, string Group, string Name, bool Enabled);

/// <summary>
/// 菜单要显示的真实规则快照。传值进来而不是让 Builder 去读全局状态，保持它纯函数、可单测。
/// </summary>
public sealed record TrayHostsSnapshot(bool ManagementOn, IReadOnlyList<TrayHostsRow> Rows)
{
    public static TrayHostsSnapshot Empty { get; } = new(true, []);
}
