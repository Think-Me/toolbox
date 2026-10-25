namespace Toolbox.Core.Settings;

/// <summary>全局热键的业务身份。数值同时用作 RegisterHotKey 的 id（要求 1..0xBFFF）。</summary>
public enum HotkeyId
{
    ClipboardPanel = 1,
    Translation = 2,
    HostsPanel = 3,
    Screenshot = 4,
    CaptureFull = 5,
    KillAllPins = 6,
}

/// <summary>
/// 热键绑定表与校验规则。刻意不碰 RegisterHotKey：探测有副作用
/// （Mac 版踩过：探测一个自己已经占着的键位永远返回"被占用"），
/// 所以真正的注册与探测留在 App 层。
/// </summary>
public sealed class HotkeyRegistrationTable
{
    private readonly Dictionary<HotkeyId, HotkeyGesture> _bindings;

    private HotkeyRegistrationTable(Dictionary<HotkeyId, HotkeyGesture> bindings) => _bindings = bindings;

    public IReadOnlyDictionary<HotkeyId, HotkeyGesture> Bindings => _bindings;

    public static HotkeyRegistrationTable From(HotkeySettings hotkeys) => new(new()
    {
        [HotkeyId.ClipboardPanel] = hotkeys.ClipboardPanel,
        [HotkeyId.Translation] = hotkeys.Translation,
        [HotkeyId.HostsPanel] = hotkeys.HostsPanel,
        [HotkeyId.Screenshot] = hotkeys.Screenshot,
        [HotkeyId.CaptureFull] = hotkeys.CaptureFull,
        [HotkeyId.KillAllPins] = hotkeys.KillAllPins,
    });

    public HotkeyGesture? Get(HotkeyId id) => _bindings.TryGetValue(id, out var gesture) ? gesture : null;

    public void Set(HotkeyId id, HotkeyGesture gesture) => _bindings[id] = gesture;

    /// <summary>把表写回设置对象，由 SettingsStore 负责落盘。</summary>
    public void ApplyTo(HotkeySettings target)
    {
        foreach (var (id, gesture) in _bindings)
        {
            switch (id)
            {
                case HotkeyId.ClipboardPanel: target.ClipboardPanel = gesture; break;
                case HotkeyId.Translation: target.Translation = gesture; break;
                case HotkeyId.HostsPanel: target.HostsPanel = gesture; break;
                case HotkeyId.Screenshot: target.Screenshot = gesture; break;
                case HotkeyId.CaptureFull: target.CaptureFull = gesture; break;
                case HotkeyId.KillAllPins: target.KillAllPins = gesture; break;
            }
        }
    }

    public static string DisplayName(HotkeyId id) => id switch
    {
        HotkeyId.ClipboardPanel => "剪贴板历史",
        HotkeyId.Translation => "划词翻译",
        HotkeyId.HostsPanel => "Hosts 快切",
        HotkeyId.Screenshot => "区域截图",
        HotkeyId.CaptureFull => "全屏截图",
        HotkeyId.KillAllPins => "关闭所有贴图",
        _ => id.ToString(),
    };

    /// <summary>null = 合法；否则是给用户看的拒绝原因。</summary>
    public static string? Validate(HotkeyGesture gesture)
    {
        if (gesture.IsEmpty) return "请按下要绑定的按键";
        var hasModifier =
            (gesture.Modifiers & (HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Win)) != 0;
        if (hasModifier) return null;
        // 裸 F1–F24 合法：不参与打字，不会误触；单独 Shift 不行。
        if (gesture.VirtualKey is >= 0x70 and <= 0x87) return null;
        return "需要 Ctrl / Alt / Win 至少一个修饰键；F1–F24 可以裸按";
    }

    /// <summary>
    /// 内部冲突检查。重录本行当前的手势是合法的（返回 null），
    /// 调用方必须据此跳过 probe —— 键在自己手上，探测必然报"被占用"。
    /// </summary>
    public static string? DetectConflict(HotkeyId id, HotkeyGesture proposed,
                                         IReadOnlyDictionary<HotkeyId, HotkeyGesture> bindings)
    {
        foreach (var (otherId, gesture) in bindings)
        {
            if (otherId == id || gesture != proposed) continue;
            return $"「{proposed}」已分配给「{DisplayName(otherId)}」，请换一个键位";
        }
        return null;
    }
}
