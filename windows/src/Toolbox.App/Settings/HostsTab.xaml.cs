using System.Windows;
using System.Windows.Controls;
using Toolbox.Core.Hosts;

namespace Toolbox.App.Settings;

/// <summary>
/// Hosts 设置页。规则勾选后立刻保存并触发后台应用（会弹 UAC）；
/// 规则的新建/内联编辑属于下一个增量，这里先把「启停 + 应用 + 恢复」跑通。
/// </summary>
internal partial class HostsTab : UserControl
{
    private readonly SettingsContext _context;
    private bool _suppressEvents;

    public HostsTab(SettingsContext context)
    {
        _context = context;
        InitializeComponent();
        Reload();
    }

    private HostsLibrary Library => _context.Hosts();

    private void Reload()
    {
        _suppressEvents = true;
        ManagementCheck.IsChecked = Library.ManagementOn;
        _suppressEvents = false;

        RulesPanel.Children.Clear();
        foreach (var group in Library.Groups)
        {
            var groupHeader = new DockPanel { Margin = new Thickness(0, 10, 0, 4) };
            groupHeader.Children.Add(new TextBlock
            {
                Text = group.Name,
                FontWeight = FontWeights.SemiBold,
            });
            var addButton = new Button
            {
                Content = "＋ 规则",
                Padding = new Thickness(8, 1, 8, 1),
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            var capturedGroup = group;
            addButton.Click += (_, _) => AddRule(capturedGroup);
            groupHeader.Children.Add(addButton);
            RulesPanel.Children.Add(groupHeader);

            foreach (var rule in group.Rules)
            {
                var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var check = new CheckBox
                {
                    Content = rule.Name,
                    IsChecked = rule.Enabled,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                var captured = rule;
                check.Click += (_, _) =>
                {
                    if (_suppressEvents) return;
                    captured.Enabled = check.IsChecked == true;
                    _context.HostsChanged();
                    SetStatus($"规则「{captured.Name}」已{(captured.Enabled ? "启用" : "停用")}，正在应用…", error: false);
                };
                row.Children.Add(check);

                // 远程规则：显示缓存状态 + 手动同步按钮
                if (rule.Kind == RuleKind.Remote)
                {
                    var state = new TextBlock
                    {
                        FontSize = 11,
                        Foreground = System.Windows.Media.Brushes.Gray,
                        Margin = new Thickness(18, 0, 6, 0),
                        VerticalAlignment = VerticalAlignment.Center,
                        MaxWidth = 220,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    };
                    UpdateRemoteStateText(state, captured);
                    row.Children.Add(state);

                    var syncButton = new Button
                    {
                        Content = "同步",
                        Padding = new Thickness(8, 1, 8, 1),
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    syncButton.Click += (_, _) => SyncRemoteRule(syncButton, state, captured);
                    row.Children.Add(syncButton);
                }

                var buttons = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Right,
                };
                var edit = new Button { Content = "编辑", Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(4, 0, 0, 0) };
                edit.Click += (_, _) => EditRule(capturedGroup, captured);
                var delete = new Button { Content = "删除", Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(4, 0, 0, 0) };
                delete.Click += (_, _) => DeleteRule(capturedGroup, captured);
                buttons.Children.Add(edit);
                buttons.Children.Add(delete);
                row.Children.Add(buttons);

                RulesPanel.Children.Add(row);
            }
        }

        SetStatus(Library.ManagementOn
            ? $"托管开启：{Library.EnabledRules.Count()} 条启用规则"
            : "托管关闭：hosts 里的 Toolbox 托管块已摘除",
            error: false);
    }

    private void OnManagementClick(object sender, RoutedEventArgs e)
    {
        if (_suppressEvents) return;

        Library.ManagementOn = ManagementCheck.IsChecked == true;
        _context.HostsChanged();
        Reload();   // 开关影响全部规则的呈现，整页重刷
    }

    private void OnRestoreClick(object sender, RoutedEventArgs e)
    {
        _context.RestoreHosts();
        SetStatus("正在恢复原始 hosts（会弹 UAC）……", error: false);
    }

    private static void UpdateRemoteStateText(TextBlock target, HostsRule rule)
    {
        if (rule.LastError is { } error)
            target.Text = $"⚠ {error}";
        else if (rule.LastSyncAt is { } at)
            target.Text = rule.CachedContent is null ? "从未同步成功" : $"缓存于 {at:MM-dd HH:mm}";
        else
            target.Text = "尚未同步";
    }

    /// <summary>同步是网络 IO（最长 15s），放后台跑；结果回 UI 线程刷新。</summary>
    private void SyncRemoteRule(Button button, TextBlock state, HostsRule rule)
    {
        var ui = TaskScheduler.FromCurrentSynchronizationContext();
        button.IsEnabled = false;
        SetStatus($"正在同步「{rule.Name}」…", error: false);

        Task.Run(() => _context.SyncHostsRule(rule)).ContinueWith(task =>
        {
            button.IsEnabled = true;
            UpdateRemoteStateText(state, rule);
            SetStatus(task.Status == TaskStatus.RanToCompletion
                ? task.Result
                : $"同步失败：{task.Exception?.GetBaseException().Message}", error: task.Status != TaskStatus.RanToCompletion);
            _context.Log($"远程规则「{rule.Name}」同步：{task.Result}");
        }, ui);
    }

    private void AddRule(RuleGroup group)
    {
        var rule = new HostsRule { Name = "新规则", Enabled = false };
        if (!RuleEditDialog.Edit(Window.GetWindow(this), rule, group.Name)) return;

        if (Library.Groups.FirstOrDefault(g => g.Name == group.Name) is not { } target)
        {
            target = new RuleGroup { Name = group.Name };
            Library.Groups.Add(target);
        }
        target.Rules.Add(rule);
        _context.HostsChanged();
        Reload();
        SetStatus($"规则「{rule.Name}」已添加（未启用，勾选后生效）", error: false);
    }

    private void EditRule(RuleGroup group, HostsRule rule)
    {
        if (!RuleEditDialog.Edit(Window.GetWindow(this), rule, group.Name)) return;
        _context.HostsChanged();
        Reload();
        SetStatus($"规则「{rule.Name}」已修改，正在应用…", error: false);
    }

    private void DeleteRule(RuleGroup group, HostsRule rule)
    {
        var confirm = MessageBox.Show(
            Window.GetWindow(this),
            $"删除规则「{rule.Name}」？",
            "Toolbox",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes) return;

        group.Rules.Remove(rule);
        if (group.Rules.Count == 0 && Library.Groups.Count > 1) Library.Groups.Remove(group);
        _context.HostsChanged();
        Reload();
        SetStatus($"规则「{rule.Name}」已删除，正在应用…", error: false);
    }

    private void SetStatus(string text, bool error)
    {
        StatusText.Text = text;
        StatusText.Foreground = error
            ? System.Windows.Media.Brushes.Firebrick
            : System.Windows.Media.Brushes.SeaGreen;
    }
}
