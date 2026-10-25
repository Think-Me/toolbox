using Toolbox.App.Hotkeys;
using Toolbox.Core.Hosts;
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

    /// <summary>规则库（实时对象，勾选后调用 HostsChanged 保存并应用）。</summary>
    public required Func<HostsLibrary> Hosts { get; init; }

    /// <summary>规则库有改动：保存 + 后台应用（会弹 UAC）。</summary>
    public required Action HostsChanged { get; init; }

    /// <summary>恢复原始 hosts 备份。</summary>
    public required Action RestoreHosts { get; init; }

    /// <summary>
    /// 同步一条远程规则（网络 IO，**请在后台线程调用**）。
    /// 返回给用户看的结果说明；规则字段（缓存/ETag/错误）由实现方就地更新。
    /// </summary>
    public required Func<HostsRule, string> SyncHostsRule { get; init; }

    /// <summary>读 DPAPI 解密后的 AI Key；没有返回空串。</summary>
    public required Func<string> LoadAiKey { get; init; }

    /// <summary>DPAPI 加密保存 AI Key。</summary>
    public required Action<string> SaveAiKey { get; init; }

    public required Action<string> Log { get; init; }
}
