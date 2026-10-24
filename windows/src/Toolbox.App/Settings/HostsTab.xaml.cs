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
            if (Library.Groups.Count > 1)
            {
                RulesPanel.Children.Add(new TextBlock
                {
                    Text = group.Name,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(0, 10, 0, 4),
                });
            }

            foreach (var rule in group.Rules)
            {
                var check = new CheckBox
                {
                    Content = rule.Name,
                    IsChecked = rule.Enabled,
                    Margin = new Thickness(0, 3, 0, 3),
                };
                var captured = rule;
                check.Click += (_, _) =>
                {
                    if (_suppressEvents) return;
                    captured.Enabled = check.IsChecked == true;
                    _context.HostsChanged();
                    SetStatus($"规则「{captured.Name}」已{(captured.Enabled ? "启用" : "停用")}，正在应用…", error: false);
                };
                RulesPanel.Children.Add(check);
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

    private void SetStatus(string text, bool error)
    {
        StatusText.Text = text;
        StatusText.Foreground = error
            ? System.Windows.Media.Brushes.Firebrick
            : System.Windows.Media.Brushes.SeaGreen;
    }
}
