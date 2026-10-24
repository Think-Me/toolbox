using System.Runtime.InteropServices;
using Toolbox.App.Shell;
using Toolbox.Core.Settings;

namespace Toolbox.App.Hotkeys;

/// <summary>一个注册不上的热键，连同原因。原因要能直接讲给用户听，不能只留错误码。</summary>
internal sealed record HotkeyFailure(HotkeyId Id, HotkeyGesture Gesture, string Reason);

/// <summary>
/// RegisterHotKey 的包装。热键 id 直接用 <see cref="HotkeyId"/> 的数值，
/// 这样 WM_HOTKEY 的 wParam 不用查表就能反查业务身份。
/// </summary>
internal sealed class HotkeyService
{
    /// <summary>探测用的临时 id，取 RegisterHotKey 允许的上界，避开业务 id。</summary>
    private const int ProbeId = 0xBFFF;

    private readonly IntPtr _window;
    private readonly HashSet<int> _registered = [];

    public HotkeyService(IntPtr window) => _window = window;

    public IReadOnlyList<HotkeyFailure> Failures { get; private set; } = [];

    /// <summary>
    /// 先全部注销再全部注册。只注销被改动的那一个的话，旧键位会继续吃按键
    /// —— Mac 版在这里踩过：改键后新旧两个键位都能触发。
    /// </summary>
    public IReadOnlyList<HotkeyFailure> RegisterAll(HotkeyRegistrationTable table)
    {
        UnregisterAll();

        var failures = new List<HotkeyFailure>();
        foreach (var id in Enum.GetValues<HotkeyId>())
        {
            var gesture = table.Get(id);
            if (gesture is not { IsEmpty: false } wanted)
            {
                failures.Add(new HotkeyFailure(id, default, "设置里没有键位"));
                continue;
            }

            if (HotkeyRegistrationTable.Validate(wanted) is { } invalid)
            {
                failures.Add(new HotkeyFailure(id, wanted, invalid));
                continue;
            }

            if (NativeMethods.RegisterHotKey(_window, (int)id, ModifiersOf(wanted), (uint)wanted.VirtualKey))
            {
                _registered.Add((int)id);
                continue;
            }

            failures.Add(new HotkeyFailure(id, wanted, Diagnose(id, wanted, table)));
        }

        Failures = failures;
        return failures;
    }

    public void UnregisterAll()
    {
        foreach (var id in _registered) NativeMethods.UnregisterHotKey(_window, id);
        _registered.Clear();
    }

    /// <summary>WM_HOTKEY 到了：true 表示这个 id 确实是我们注册的。</summary>
    public bool Dispatch(int id) => _registered.Contains(id);

    /// <summary>
    /// 探测某个键位现在能不能拿到。**仅用于用户正在录制的新键位**：
    /// 探测会真的注册再释放，拿自己已经占着的键位去探必然返回 false。
    /// </summary>
    public bool Probe(HotkeyGesture gesture)
    {
        if (!NativeMethods.RegisterHotKey(_window, ProbeId, ModifiersOf(gesture), (uint)gesture.VirtualKey))
            return false;
        NativeMethods.UnregisterHotKey(_window, ProbeId);
        return true;
    }

    /// <summary>
    /// 注册失败后判断原因。内部重复能静态查出来（设置里两条规则撞了同一个键），
    /// 查不出来才是被别的程序抢注 —— 后者靠 Win32 的 1409。
    /// </summary>
    private static string Diagnose(HotkeyId id, HotkeyGesture gesture, HotkeyRegistrationTable table)
    {
        if (HotkeyRegistrationTable.DetectConflict(id, gesture, table.Bindings) is { } conflict) return conflict;

        var code = Marshal.GetLastWin32Error();
        return code == NativeMethods.ErrorHotkeyAlreadyRegistered
            ? $"已被其它程序占用（和 Snipaste / SwitchHosts 等先注册者冲突），Win32 错误 {code}"
            : $"注册失败，Win32 错误 {code}";
    }

    /// <summary>HotkeyModifiers 的位值恰好等于 MOD_ALT/CONTROL/SHIFT/WIN，直接转。</summary>
    private static uint ModifiersOf(HotkeyGesture gesture) =>
        (uint)gesture.Modifiers | NativeMethods.ModNoRepeat;
}
