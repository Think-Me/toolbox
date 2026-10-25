using System.Windows;
using System.Windows.Controls;
using Toolbox.Core.Hosts;

namespace Toolbox.App.Settings;

/// <summary>
/// 规则新建/编辑对话框。OK 返回规则（编辑时原地改），Cancel 返回 null。
/// 类型切换会改 source 字段的形态：内联多行 / 本地文件路径 / 远程 URL。
/// </summary>
internal sealed class RuleEditDialog : Window
{
    private static readonly (RuleKind Kind, string Label)[] KindOptions =
    [
        (RuleKind.Inline, "内联内容"),
        (RuleKind.LocalFile, "本地文件"),
        (RuleKind.Remote, "远程 URL"),
    ];

    private readonly TextBox _nameBox = new() { Width = 280 };
    private readonly TextBox _groupBox = new() { Width = 280 };
    private readonly ComboBox _kindBox = new() { Width = 280 };
    private readonly TextBox _sourceBox = new()
    {
        Width = 280,
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = new System.Windows.Media.FontFamily("Consolas"),
    };
    private readonly TextBlock _hint = new()
    {
        Foreground = System.Windows.Media.Brushes.Gray,
        FontSize = 11,
        Margin = new Thickness(0, 4, 0, 0),
        TextWrapping = TextWrapping.Wrap,
    };
    private readonly TextBlock _sourceLabel = new() { Text = "内容", VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 5, 8, 0) };

    private bool _suppressKindSync;

    public HostsRule Rule { get; }

    public RuleEditDialog(HostsRule rule, string defaultGroup)
    {
        Rule = rule;
        Title = "Hosts 规则";
        Width = 360;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;

        _nameBox.Text = rule.Name;
        _groupBox.Text = defaultGroup;
        foreach (var (kind, label) in KindOptions)
            _kindBox.Items.Add(new ComboBoxItem { Content = label, Tag = kind });

        _kindBox.SelectionChanged += (_, _) =>
        {
            if (_suppressKindSync) return;
            SyncKindUi();
        };

        var grid = new Grid { Margin = new Thickness(14) };
        for (var i = 0; i < 5; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        AddRow(grid, 0, "名称", _nameBox);
        AddRow(grid, 1, "分组", _groupBox);
        AddRow(grid, 2, "类型", _kindBox);
        Grid.SetRow(_sourceLabel, 3);
        Grid.SetColumn(_sourceLabel, 0);
        grid.Children.Add(_sourceLabel);
        Grid.SetRow(_sourceBox, 3);
        Grid.SetColumn(_sourceBox, 1);
        grid.Children.Add(_sourceBox);
        Grid.SetRow(_hint, 4);
        Grid.SetColumn(_hint, 1);
        grid.Children.Add(_hint);

        // 编辑时按已有类型初始化；显示当前缓存状态帮用户判断要不要点同步
        _suppressKindSync = true;
        _kindBox.SelectedIndex = IndexOfKind(rule.Kind);
        _suppressKindSync = false;
        SyncKindUi();

        if (rule.Kind == RuleKind.Remote && rule.LastError is { } error)
            _hint.Text += $"\n上次同步失败：{error}";

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        var ok = new Button { Content = "确定", Padding = new Thickness(18, 4, 18, 4) };
        ok.Click += OnOk;
        var cancel = new Button { Content = "取消", Padding = new Thickness(18, 4, 18, 4), Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        Grid.SetRow(buttons, 5);
        Grid.SetColumnSpan(buttons, 2);
        grid.Children.Add(buttons);
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        Content = grid;
    }

    private int IndexOfKind(RuleKind kind)
    {
        for (var i = 0; i < KindOptions.Length; i++)
            if (KindOptions[i].Kind == kind) return i;
        return 0;
    }

    private RuleKind SelectedKind =>
        _kindBox.SelectedItem is ComboBoxItem { Tag: RuleKind kind } ? kind : RuleKind.Inline;

    private void SyncKindUi()
    {
        switch (SelectedKind)
        {
            case RuleKind.Inline:
                _sourceLabel.Text = "内容";
                _sourceBox.Height = 120;
                _sourceBox.AcceptsReturn = true;
                _hint.Text = "每行一条：IP 域名。支持 # 注释。";
                break;
            case RuleKind.LocalFile:
                _sourceLabel.Text = "路径";
                _sourceBox.Height = double.NaN;
                _sourceBox.AcceptsReturn = false;
                _hint.Text = "本机 hosts 片段文件的完整路径。文件不存在时这条规则按空内容处理。";
                break;
            case RuleKind.Remote:
                _sourceLabel.Text = "URL";
                _sourceBox.Height = double.NaN;
                _sourceBox.AcceptsReturn = false;
                _hint.Text = "http(s) 地址。同步走 ETag 条件请求，失败但有缓存时离线仍可用。";
                break;
        }
    }

    private static void AddRow(Grid grid, int row, string label, Control control)
    {
        grid.Children.Add(new TextBlock
        {
            Text = label,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 5, 8, 0),
        });
        Grid.SetRow(control, row);
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_nameBox.Text) || string.IsNullOrWhiteSpace(_sourceBox.Text))
        {
            _ = MessageBox.Show(this, "名称和内容都不能为空", "Toolbox", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var kind = SelectedKind;
        if (kind == RuleKind.Remote &&
            (!Uri.TryCreate(_sourceBox.Text.Trim(), UriKind.Absolute, out var uri) ||
             uri.Scheme is not ("http" or "https")))
        {
            _ = MessageBox.Show(this, "远程规则需要有效的 http(s) URL", "Toolbox", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Rule.Name = _nameBox.Text.Trim();
        Rule.Source = _sourceBox.Text.Trim();
        if (Rule.Kind != kind)
        {
            // 类型换了：旧缓存/错误不再有意义
            Rule.Kind = kind;
            Rule.CachedContent = null;
            Rule.ETag = null;
            Rule.LastError = null;
        }
        DialogResult = true;
    }

    /// <summary>显示对话框。返回 true 表示用户点了确定（rule 已就地更新）。</summary>
    public static bool Edit(Window owner, HostsRule rule, string defaultGroup)
    {
        var dialog = new RuleEditDialog(rule, defaultGroup) { Owner = owner };
        return dialog.ShowDialog() == true;
    }
}
