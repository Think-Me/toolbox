using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Toolbox.Core.Clipboard;

namespace Toolbox.App.Clipboard;

/// <summary>
/// 剪贴板历史面板。无边框、置顶、不占任务栏。
///
/// 两个行为约定：
/// - 一旦失焦就隐藏（点别处即关闭），否则它会一直浮在最上层挡着别的窗口；
/// - 粘贴前**先把自己藏起来**再切前台。我们自己是前台窗口时，合成的 Ctrl+V 会打进自己，
///   表现就是"内容复制了但要再按一次"（Mac 版踩过同一个坑）。
/// </summary>
internal partial class ClipboardPanelWindow : Window
{
    private readonly ClipboardStore _store;
    private readonly Func<ClipboardItem, (PasteOutcome Outcome, string Message)> _paste;
    private readonly Action<string> _report;

    private List<ClipboardItem> _items = [];
    private ClipboardListSelection _selection = new(0);
    private bool _suppressReload;

    public ClipboardPanelWindow(ClipboardStore store,
                                Func<ClipboardItem, (PasteOutcome Outcome, string Message)> paste,
                                Action<string> report)
    {
        _store = store;
        _paste = paste;
        _report = report;

        InitializeComponent();
        PreviewKeyDown += OnPreviewKeyDown;
    }

    public void ShowPanel()
    {
        _suppressReload = true;
        SearchBox.Text = "";
        _suppressReload = false;

        Reload();
        PositionOnScreen();

        Show();
        Activate();
        SearchBox.Focus();
    }

    /// <summary>居中到主屏工作区。多显示器下会出现在主屏，属于已知限制。</summary>
    private void PositionOnScreen()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + (area.Height - Height) / 2;
    }

    private void Reload()
    {
        _items = _store.List(SearchBox.Text, 200).ToList();
        ItemsList.ItemsSource = _items;
        _selection.ApplyFilter(_items.Count);
        SyncSelection();

        StatusText.Text = _items.Count == 0
            ? "没有匹配的记录"
            : $"{_items.Count} 条 · ↑↓ 选择 · Enter 粘贴 · Ctrl+P 置顶 · Del 删除 · Esc 关闭";
    }

    /// <summary>用键盘改了选中行之后，把 ListBox 的高亮跟上，两者不能各说各话。</summary>
    private void SyncSelection()
    {
        ItemsList.SelectedIndex = _selection.IsValid ? _selection.Index : -1;
        if (_selection.IsValid) ItemsList.ScrollIntoView(ItemsList.SelectedItem);
    }

    private ClipboardItem? Current =>
        _selection.IsValid && _selection.Index < _items.Count ? _items[_selection.Index] : null;

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressReload || !IsLoaded) return;
        Reload();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                Hide();
                e.Handled = true;
                return;

            case Key.Enter:
                ActivateCurrent();
                e.Handled = true;
                return;

            case Key.Up:
                Move(-1);
                e.Handled = true;
                return;

            case Key.Down:
                Move(1);
                e.Handled = true;
                return;

            case Key.Delete:
                DeleteCurrent();
                e.Handled = true;
                return;

            case Key.P when Keyboard.Modifiers == ModifierKeys.Control:
                TogglePin();
                e.Handled = true;
                return;
        }

        // Ctrl+1…Ctrl+9 快粘
        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key is >= Key.D1 and <= Key.D9)
        {
            var digit = e.Key - Key.D0;
            if (_selection.QuickPick(digit) is { } index)
            {
                _selection.Select(index);
                ActivateCurrent();
            }
            e.Handled = true;
        }
    }

    private void Move(int delta)
    {
        _selection.Move(delta);
        SyncSelection();
    }

    private void ActivateCurrent()
    {
        var item = Current;
        if (item is null) return;

        // 先藏自己：否则合成的 Ctrl+V 会回到本面板而不是目标窗口
        Hide();

        var (outcome, message) = _paste(item);
        if (outcome != PasteOutcome.Pasted && !string.IsNullOrEmpty(message)) _report(message);
    }

    private void DeleteCurrent()
    {
        var item = Current;
        if (item is null) return;

        _store.Delete(item.Id);
        Reload();
    }

    private void TogglePin()
    {
        var item = Current;
        if (item is null) return;

        _store.SetPinned(item.Id, !item.Pinned);
        Reload();

        // 置顶会改变排序，让它回到列表顶部并保持选中，避免"按了没反应"的错觉
        var index = _items.FindIndex(i => i.Id == item.Id);
        if (index >= 0)
        {
            _selection.Select(index);
            SyncSelection();
        }
    }

    private void OnItemDoubleClick(object sender, MouseButtonEventArgs e) => ActivateCurrent();

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        Hide();
    }
}
