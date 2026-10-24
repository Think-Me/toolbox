using Toolbox.App.Hotkeys;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Settings;

namespace Toolbox.App.Settings;

/// <summary>设置窗需要的全部外部能力，收成一个对象，窗口自己不去碰全局状态（也就好测）。</summary>
internal sealed class SettingsContext
{
    public required AppPaths Paths { get; init; }

    public required AppSettings Settings { get; init; }

    public required HotkeyRegistrationTable Hotkeys { get; init; }

    public required IReadOnlyList<HotkeyFailure> Failures { get; init; }

    /// <summary>探测键位是否空闲。会真的注册再释放，**只能对新键位**用。</summary>
    public required Func<HotkeyGesture, bool> ProbeFree { get; init; }

    /// <summary>绑定表改完后调用：写盘 + 重新注册全部热键，返回注册失败的项。</summary>
    public required Func<IReadOnlyList<HotkeyFailure>> ApplyHotkeys { get; init; }

    /// <summary>整份设置落盘。</summary>
    public required Action SaveSettings { get; init; }

    /// <summary>读 DPAPI 解密后的 AI Key；没有返回空串。</summary>
    public required Func<string> LoadAiKey { get; init; }

    /// <summary>DPAPI 加密保存 AI Key。</summary>
    public required Action<string> SaveAiKey { get; init; }

    public required Action<string> Log { get; init; }
}
