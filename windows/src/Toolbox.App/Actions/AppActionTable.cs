using Toolbox.Core.Settings;
using Toolbox.Core.Shell;

namespace Toolbox.App.Actions;

/// <summary>
/// 动作表：托盘菜单项和全局热键共用同一份实现。
/// Mac 版的教训 —— 菜单一套闭包、热键一套闭包，两条路径的行为迟早分叉。
/// </summary>
internal sealed class AppActionTable
{
    private readonly Dictionary<TrayAction, Action<Guid?>> _handlers = [];

    public void Bind(TrayAction action, Action<Guid?> handler) => _handlers[action] = handler;

    /// <summary>没有绑定处理器时返回 false，让调用方知道"这行菜单是死的"。</summary>
    public bool Invoke(TrayAction action, Guid? ruleId = null)
    {
        if (!_handlers.TryGetValue(action, out var handler)) return false;
        handler(ruleId);
        return true;
    }

    /// <summary>热键 → 菜单动作。热键回调走这条路，保证"按热键"和"点菜单"是同一件事。</summary>
    public static TrayAction ForHotkey(HotkeyId id) => id switch
    {
        HotkeyId.ClipboardPanel => TrayAction.Clipboard,
        HotkeyId.Translation => TrayAction.Translate,
        HotkeyId.HostsPanel => TrayAction.HostsPanel,
        HotkeyId.Screenshot => TrayAction.CaptureRegion,
        _ => TrayAction.None,
    };
}
