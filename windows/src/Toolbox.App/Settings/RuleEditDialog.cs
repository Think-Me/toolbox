using System.Windows;
using System.Windows.Controls;
using Toolbox.Core.Hosts;

namespace Toolbox.App.Settings;

/// <summary>
/// 规则新建/编辑对话框。OK 返回规则（编辑时原地改），Cancel 返回 null。
/// </summary>
internal sealed class RuleEditDialog : Window
{
    private readonly TextBox _nameBox = new() { Width = 280 };
    private readonly TextBox _groupBox = new() { Width = 280 };
    private readonly TextBox _contentBox = new()
    {
        Width = 280,
        Height = 120,
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = new System.Windows.Media.FontFamily("Consolas"),
    };

    public HostsRule Rule { get; }

    public RuleEditDialog(HostsRule rule, string defaultGroup)
    {
        Rule = rule;
        Title = "Hosts 规则";
        Width = 340;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;

        _nameBox.Text = rule.Name;
        _groupBox.Text = defaultGroup;
        _contentBox.Text = rule.Source;

        var grid = new Grid { Margin = new Thickness(14) };
        for (var i = 0; i < 3; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        AddRow(grid, 0, "名称", _nameBox);
        AddRow(grid, 1, "分组", _groupBox);
        AddRow(grid, 2, "内容", _contentBox);
        var hint = new TextBlock
        {
            Text = "每行一条：IP 域名。支持 # 注释。",
            Foreground = System.Windows.Media.Brushes.Gray,
            FontSize = 11,
            Margin = new Thickness(0, 4, 0, 0),
        };
        Grid.SetRow(hint, 3);
        Grid.SetColumn(hint, 1);
        grid.Children.Add(hint);

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
        Grid.SetRow(buttons, 4);
        Grid.SetColumnSpan(buttons, 2);
        grid.Children.Add(buttons);

        Content = grid;
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
        if (string.IsNullOrWhiteSpace(_nameBox.Text) || string.IsNullOrWhiteSpace(_contentBox.Text))
        {
            _ = MessageBox.Show(this, "名称和内容都不能为空", "Toolbox", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Rule.Name = _nameBox.Text.Trim();
        Rule.Source = _contentBox.Text;
        Rule.Kind = RuleKind.Inline;
        DialogResult = true;
    }

    /// <summary>显示对话框。返回 true 表示用户点了确定（rule 已就地更新）。</summary>
    public static bool Edit(Window owner, HostsRule rule, string defaultGroup)
    {
        var dialog = new RuleEditDialog(rule, defaultGroup) { Owner = owner };
        return dialog.ShowDialog() == true;
    }
}
