using Toolbox.Core.Shell;

namespace Toolbox.App.Shell;

/// <summary>
/// 原生右键菜单。不用 WPF 的 ContextMenu：托盘点击时本进程并不是激活窗口，
/// WPF 弹出层没有 capture owner，点别处菜单不会消失，要额外补一大堆 foreground/capture 处理。
/// 原生 HMENU 自带 click-away、Esc、键盘导航、DPI 缩放和深色模式。
/// </summary>
internal sealed class TrayMenu
{
    private readonly IntPtr _window;
    private readonly Dictionary<int, TrayAction> _actions = [];
    private readonly Dictionary<int, Guid> _rules = [];
    private int _nextCommandId = 1;

    public TrayMenu(IntPtr window) => _window = window;

    /// <summary>弹出菜单并返回用户选中的动作。取消时返回 (None, null)。</summary>
    public (TrayAction Action, Guid? RuleId) Show(IReadOnlyList<TrayMenuItem> items)
    {
        if (!NativeMethods.GetCursorPos(out var cursor)) return (TrayAction.None, null);

        var menu = NativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero) return (TrayAction.None, null);

        _actions.Clear();
        _rules.Clear();
        _nextCommandId = 1;

        try
        {
            Append(menu, items);

            // 这三步缺一不可，否则"点菜单外面菜单不消失"（Win32 的老问题）
            NativeMethods.SetForegroundWindow(_window);
            var command = NativeMethods.TrackPopupMenuEx(
                menu,
                NativeMethods.TpmReturnCmd | NativeMethods.TpmRightButton,
                cursor.X, cursor.Y, _window, IntPtr.Zero);
            NativeMethods.PostMessage(_window, NativeMethods.WmNull, IntPtr.Zero, IntPtr.Zero);

            if (command == 0) return (TrayAction.None, null);

            _actions.TryGetValue(command, out var action);
            _rules.TryGetValue(command, out var ruleId);
            return (action, _rules.ContainsKey(command) ? ruleId : null);
        }
        finally
        {
            NativeMethods.DestroyMenu(menu);
        }
    }

    /// <summary>每次打开都重建 HMENU，不复用：缓存菜单会让"暂停/自启"的勾选停在旧值。</summary>
    private void Append(IntPtr menu, IReadOnlyList<TrayMenuItem> items)
    {
        foreach (var item in items)
        {
            if (item.IsSeparator)
            {
                NativeMethods.AppendMenu(menu, NativeMethods.MfSeparator, UIntPtr.Zero, null);
                continue;
            }

            if (item.HasChildren)
            {
                var submenu = NativeMethods.CreatePopupMenu();
                Append(submenu, item.Children);

                var flags = NativeMethods.MfPopup;
                if (!item.IsEnabled) flags |= NativeMethods.MfGrayed;
                NativeMethods.AppendMenu(menu, flags, HandleToId(submenu), Label(item));
                continue;
            }

            var id = _nextCommandId++;
            var leafFlags = NativeMethods.MfString;
            if (!item.IsEnabled) leafFlags |= NativeMethods.MfGrayed;
            if (item.IsChecked) leafFlags |= NativeMethods.MfChecked;
            NativeMethods.AppendMenu(menu, leafFlags, new UIntPtr((uint)id), Label(item));

            if (item.Action != TrayAction.None) _actions[id] = item.Action;
            if (item.RuleId is { } ruleId) _rules[id] = ruleId;
        }
    }

    /// <summary>Win32 菜单把 \t 之后的文字右对齐，正好用来放快捷键。</summary>
    private static string Label(TrayMenuItem item) =>
        item.Shortcut is null ? item.Title : $"{item.Title}\t{item.Shortcut}";

    private static UIntPtr HandleToId(IntPtr handle) => new(unchecked((ulong)handle.ToInt64()));
}
