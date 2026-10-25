using System.Windows;
using System.Windows.Controls;
using Toolbox.Core.Clipboard;
using Toolbox.Core.Settings;

namespace Toolbox.App.Settings;

/// <summary>
/// 剪贴板设置页。保存时把排除列表换成新 List 实例 —— ClipboardFilter
/// 按引用缓存这个列表，换实例才会让它重建。
/// </summary>
internal partial class ClipboardTab : UserControl
{
    private readonly ClipboardSettings _settings;
    private readonly Action _save;

    public ClipboardTab(ClipboardSettings settings, Action save)
    {
        _settings = settings;
        _save = save;
        InitializeComponent();
        Reload();
    }

    private void Reload()
    {
        MaxItemsBox.Text = _settings.MaxItems.ToString();
        MaxTextLengthBox.Text = _settings.MaxTextLength.ToString();
        MaxImageMbBox.Text = _settings.MaxImageMegabytes.ToString();
        SelfWriteMsBox.Text = _settings.SelfWriteIgnoreMilliseconds.ToString();

        ExcludedList.Items.Clear();
        foreach (var process in _settings.ExcludedProcesses) ExcludedList.Items.Add(process);
    }

    private void OnAddProcessClick(object sender, RoutedEventArgs e)
    {
        var name = ClipboardFilter.NormalizeProcess(NewProcessBox.Text);
        if (name.Length == 0) return;
        if (ExcludedList.Items.Contains(name))
        {
            NewProcessBox.Clear();
            return;
        }

        ExcludedList.Items.Add(name);
        NewProcessBox.Clear();
    }

    private void OnRemoveProcessClick(object sender, RoutedEventArgs e)
    {
        if (ExcludedList.SelectedIndex is >= 0 and var index)
            ExcludedList.Items.RemoveAt(index);
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (!TryReadInt(MaxItemsBox, 10, 10_000, out var maxItems) ||
            !TryReadInt(MaxTextLengthBox, 100, 10_000_000, out var maxText) ||
            !TryReadInt(MaxImageMbBox, 1, 500, out var maxImageMb) ||
            !TryReadInt(SelfWriteMsBox, 100, 10_000, out var selfWriteMs))
        {
            SaveStatus.Text = "数值无效，请检查";
            SaveStatus.Foreground = System.Windows.Media.Brushes.Firebrick;
            return;
        }

        _settings.MaxItems = maxItems;
        _settings.MaxTextLength = maxText;
        _settings.MaxImageMegabytes = maxImageMb;
        _settings.SelfWriteIgnoreMilliseconds = selfWriteMs;
        // 换新 List 实例：ClipboardFilter 的排除缓存按引用判断，不换就不会生效
        _settings.ExcludedProcesses = ExcludedList.Items.Cast<string>().ToList();

        _save();
        Reload();
        SaveStatus.Text = "已保存，立即生效";
        SaveStatus.Foreground = System.Windows.Media.Brushes.SeaGreen;
    }

    private bool TryReadInt(TextBox box, int min, int max, out int value)
    {
        value = 0;
        return int.TryParse(box.Text.Trim(), out value) && value >= min && value <= max;
    }
}
