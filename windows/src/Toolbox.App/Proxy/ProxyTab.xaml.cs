using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Toolbox.Core.Proxy;

namespace Toolbox.App.Proxy;

/// <summary>
/// 代理设置页。所有网络操作放后台线程；Controller.Changed 在线程池触发，
/// 统一经 Dispatcher 调度回 UI 再刷新。
/// </summary>
internal partial class ProxyTab : UserControl
{
    private readonly ProxyController _controller;
    private (string? CoreLatest, string? RulesLatest) _updates;
    private bool _suppressEvents;

    public ProxyTab(ProxyController controller)
    {
        _controller = controller;
        InitializeComponent();
        RoutingCombo.ItemsSource = Enum.GetValues<ProxyRoutingMode>()
            .Select(m => new ComboBoxItem { Content = m.Label(), Tag = m })
            .ToList();
        RoutingCombo.SelectionChanged += OnRoutingChanged;

        // Controller 的事件来自线程池，必须调度回 UI 线程
        _controller.Changed += () => Dispatcher.BeginInvoke(() => { if (IsLoaded) Reload(); });
        Loaded += (_, _) => Reload();
    }

    private ProxyLibrary Library => _controller.Library;

    private void Reload()
    {
        _suppressEvents = true;
        try
        {
            // 引擎
            var running = _controller.IsEngineRunning;
            EngineStateText.Text = _controller.EngineAvailable
                ? (running ? "运行中" : "已停止")
                : "未安装（可点「更新内核」获取）";
            EngineStateText.Foreground = running
                ? System.Windows.Media.Brushes.SeaGreen
                : System.Windows.Media.Brushes.Gray;
            EngineButton.Content = running ? "停止" : "启动";

            // 节点列表：行 = 勾选(候选) + 名称/摘要 + 设为当前 + 删除
            NodeList.Items.Clear();
            foreach (var node in Library.Nodes)
                NodeList.Items.Add(BuildNodeRow(node));

            // 运行时
            SocksPortBox.Text = Library.Runtime.SocksPort.ToString();
            HttpPortBox.Text = Library.Runtime.HttpPort.ToString();
            if (RoutingCombo.SelectedItem is null)
                RoutingCombo.SelectedIndex = (int)Library.Runtime.RoutingMode;
            AutoSwitchCheck.IsChecked = Library.Runtime.AutoSwitch;
            SystemProxyCheck.IsChecked = _controller.SystemProxyOn;
            SystemProxyCheck.IsEnabled = _controller.EngineAvailable;

            // 版本与更新按钮
            var (core, rules) = ProxyAssetUpdate.CurrentVersions(_controller.WorkDirectory);
            VersionText.Text = $"内核 {core} · 规则 {rules ?? "未安装"}";
            CoreUpdateButton.IsEnabled = _updates.CoreLatest is not null;
            RulesUpdateButton.IsEnabled = _updates.RulesLatest is not null;

            MessageText.Text = _controller.Message ?? "";
        }
        finally
        {
            _suppressEvents = false;
        }
    }

    private FrameworkElement BuildNodeRow(ProxyNode node)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var candidate = new CheckBox
        {
            IsChecked = node.BalancerCandidate,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = "加入自动切换候选组",
        };
        candidate.Click += (_, _) =>
        {
            if (!_suppressEvents) _controller.ToggleCandidate(node.Id);
        };
        Grid.SetColumn(candidate, 0);
        row.Children.Add(candidate);

        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(new TextBlock
        {
            Text = (node.Id == Library.ActiveNodeId ? "● " : "") + node.Name,
            FontWeight = node.Id == Library.ActiveNodeId ? FontWeights.SemiBold : FontWeights.Normal,
        });
        info.Children.Add(new TextBlock
        {
            Text = node.Summary,
            FontSize = 11,
            Foreground = System.Windows.Media.Brushes.Gray,
        });
        Grid.SetColumn(info, 1);
        row.Children.Add(info);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var use = new Button { Content = "设为当前", Padding = new Thickness(8, 1, 8, 1) };
        use.Click += (_, _) =>
        {
            if (!_suppressEvents) _controller.Select(node.Id);
            Reload();
        };
        var delete = new Button { Content = "删除", Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(4, 0, 0, 0) };
        delete.Click += (_, _) =>
        {
            if (_suppressEvents) return;
            if (MessageBox.Show(Window.GetWindow(this), $"删除节点「{node.Name}」？",
                    "Toolbox", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                _controller.Remove(node.Id);
            Reload();
        };
        buttons.Children.Add(use);
        buttons.Children.Add(delete);
        Grid.SetColumn(buttons, 2);
        row.Children.Add(buttons);

        return row;
    }

    private async void OnEngineClick(object sender, RoutedEventArgs e)
    {
        // 首次启动可能要下 geo 规则（几 MB~几十 MB），放后台
        EngineButton.IsEnabled = false;
        await Task.Run(_controller.ToggleEngine);
        EngineButton.IsEnabled = true;
        Reload();
    }

    private async void OnLatencyClick(object sender, RoutedEventArgs e)
    {
        LatencyText.Text = "测试中…";
        var (ok, detail) = await Task.Run(_controller.TestLatency);
        LatencyText.Text = ok ? $"延迟 {detail}" : $"不通：{detail}";
    }

    private void OnAddClick(object sender, RoutedEventArgs e)
    {
        if (_controller.AddFromLink(AddLinkBox.Text) is { } error)
            MessageText.Text = error;
        else
            AddLinkBox.Clear();
        Reload();
    }

    private void OnPortsClick(object sender, RoutedEventArgs e)
    {
        if (int.TryParse(SocksPortBox.Text.Trim(), out var socks) &&
            int.TryParse(HttpPortBox.Text.Trim(), out var http))
            _controller.SetPorts(socks, http);
        Reload();
    }

    private void OnRoutingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressEvents || RoutingCombo.SelectedItem is not ComboBoxItem { Tag: ProxyRoutingMode mode })
            return;
        _controller.SetMode(mode);
        Reload();
    }

    private void OnAutoSwitchClick(object sender, RoutedEventArgs e)
    {
        if (!_suppressEvents) _controller.SetAutoSwitch(AutoSwitchCheck.IsChecked == true);
        Reload();
    }

    private void OnSystemProxyClick(object sender, RoutedEventArgs e)
    {
        if (_suppressEvents) return;
        if (_controller.ToggleSystemProxy() is { } error) MessageText.Text = error;
        Reload();
    }

    private async void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        MessageText.Text = "检查中…";
        try
        {
            var (coreCurrent, coreLatest, rulesCurrent, rulesLatest) =
                await Task.Run(_controller.CheckUpdates);
            _updates = (coreLatest, rulesLatest);
            VersionText.Text = $"内核 {coreCurrent}（最新 {coreLatest ?? "?"}） · 规则 {rulesCurrent ?? "未安装"}（最新 {rulesLatest ?? "?"}）";
            MessageText.Text = coreLatest is null && rulesLatest is null
                ? "检查失败（网络不可达或被墙）"
                : ProxyVersion.IsNewer(coreLatest, coreCurrent) || ProxyVersion.IsNewer(rulesLatest, rulesCurrent)
                    ? "有可用更新"
                    : "已是最新";
        }
        catch (Exception error)
        {
            MessageText.Text = "检查失败：" + error.Message;
        }
        Reload();
    }

    private async void OnCoreUpdateClick(object sender, RoutedEventArgs e)
    {
        if (_updates.CoreLatest is not { } tag) return;
        CoreUpdateButton.IsEnabled = false;
        MessageText.Text = $"下载内核 {tag}…（几十 MB，视网络而定）";
        try
        {
            await Task.Run(() => _controller.ApplyCoreUpdate(tag));
            MessageText.Text = _controller.Message;
        }
        catch (Exception error)
        {
            MessageText.Text = "内核更新失败：" + error.Message;
        }
        Reload();
    }

    private async void OnRulesUpdateClick(object sender, RoutedEventArgs e)
    {
        if (_updates.RulesLatest is not { } tag) return;
        RulesUpdateButton.IsEnabled = false;
        MessageText.Text = $"下载规则库 {tag}…";
        try
        {
            await Task.Run(() => _controller.ApplyRulesUpdate(tag));
            MessageText.Text = _controller.Message;
        }
        catch (Exception error)
        {
            MessageText.Text = "规则库更新失败：" + error.Message;
        }
        Reload();
    }
}
