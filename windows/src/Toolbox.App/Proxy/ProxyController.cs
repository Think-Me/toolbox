using System.Diagnostics;
using System.IO;
using Toolbox.Core.Infrastructure;
using Toolbox.Core.Proxy;

namespace Toolbox.App.Proxy;

/// <summary>
/// 代理模块的编排层（对齐 macOS ProxyViewModel 的职责，不含 UI）：
/// 解析/编译/进程/系统代理都已各自单测，这里只做粘合。
/// 状态变化通过事件抛出（线程池线程），UI 侧自行调度。
/// </summary>
internal sealed class ProxyController
{
    private readonly AppPaths _paths;
    private readonly ProxyStore _store;
    private readonly Action<string> _log;
    private readonly XrayRunner _runner;
    private readonly string _configFile;

    public ProxyLibrary Library { get; private set; }
    public bool EngineAvailable { get; }
    public bool SystemProxyOn { get; private set; }
    public bool IsEngineRunning => _runner.IsRunning;

    /// <summary>xray 工作目录（内核/geo 规则/config.json 所在）。</summary>
    public string WorkDirectory => _paths.ProxyDirectory;

    /// <summary>状态变化通知（线程池线程触发，UI 侧自行调度）。</summary>
    public event Action? Changed;

    public ProxyController(AppPaths paths, Action<string> log)
    {
        _paths = paths;
        _log = log;
        _store = new ProxyStore(paths.ProxyLibrary);
        Library = _store.Load();

        string? enginePath = null;
        try
        {
            // 随包目录 = App 安装目录下的 proxy\（用户手动放入或发布时打包）
            var appDir = AppContext.BaseDirectory;
            enginePath = XrayBootstrap.EnsureInstalled(paths.ProxyDirectory,
                Directory.Exists(Path.Combine(appDir, "proxy")) ? Path.Combine(appDir, "proxy") : null);
        }
        catch (Exception error)
        {
            _log($"代理内核未就绪：{error.Message}");
        }

        EngineAvailable = enginePath is not null;
        _configFile = Path.Combine(paths.ProxyDirectory, "config.json");
        var exePath = enginePath ?? Path.Combine(paths.ProxyDirectory, "xray.exe");
        _runner = new XrayRunner(
            () => new ProcessXray(exePath, $"run -c \"{_configFile}\"", paths.ProxyDirectory),
            _configFile);
        _runner.OnStateChange = (state, message) =>
        {
            _log($"代理引擎 → {state} {message}");
            Changed?.Invoke();
        };
        SystemProxyOn = SystemProxyWin.IsEnabled();
    }

    /// <summary>手动模式看选中节点；自动切换模式看候选组——候选组为空时内核起不来。</summary>
    public static bool HasUsableNode(ProxyLibrary library) =>
        library.Runtime.AutoSwitch
            ? library.Nodes.Any(n => n.BalancerCandidate)
            : library.ActiveNode is not null;

    /// <summary>启动时调用：有可用节点就自动拉起内核。不碰系统代理。</summary>
    public void AutoStartIfPossible()
    {
        if (!IsEngineRunning && EngineAvailable && HasUsableNode(Library))
            StartEngine();
    }

    // ---- 节点增删改 ----

    /// <summary>粘贴一条分享链接添加。返回错误提示（null = 成功）。</summary>
    public string? AddFromLink(string link)
    {
        if (NodeLinkParser.TryParse(link, out var node) is { } error) return error;

        ProxyStore.Add(Library, node!);
        Persist();
        Message = $"已添加「{node!.Name}」";
        if (IsEngineRunning) StartEngine();   // 改了节点，重启生效
        Changed?.Invoke();
        return null;
    }

    public void Remove(Guid id)
    {
        ProxyStore.Remove(Library, id);
        Persist();
        if (IsEngineRunning) StartEngine();
        Changed?.Invoke();
    }

    public void Select(Guid id)
    {
        ProxyStore.SetActive(Library, id);
        Persist();
        if (IsEngineRunning) StartEngine();
        Changed?.Invoke();
    }

    public void ToggleCandidate(Guid id)
    {
        if (Library.Nodes.FirstOrDefault(n => n.Id == id) is not { } node) return;
        node.BalancerCandidate = !node.BalancerCandidate;
        Persist();
        if (IsEngineRunning && Library.Runtime.AutoSwitch) RestartEngine();
        Changed?.Invoke();
    }

    public void SetMode(ProxyRoutingMode mode)
    {
        Library.Runtime.RoutingMode = mode;
        Persist();
        if (IsEngineRunning) RestartEngine();
        Changed?.Invoke();
    }

    public void SetAutoSwitch(bool on)
    {
        Library.Runtime.AutoSwitch = on;
        Persist();
        if (IsEngineRunning) RestartEngine();
        Changed?.Invoke();
    }

    public void SetPorts(int socks, int http)
    {
        if (socks is <= 0 or >= 65536 || http is <= 0 or >= 65536) return;
        Library.Runtime.SocksPort = socks;
        Library.Runtime.HttpPort = http;
        Persist();
        if (IsEngineRunning) RestartEngine();
        if (SystemProxyOn) SystemProxyWin.Enable(http, socks);   // 端口变了重指
        Changed?.Invoke();
    }

    // ---- 引擎 ----

    public string? Message { get; private set; }

    public void StartEngine()
    {
        if (!EngineAvailable)
        {
            Message = "内核未就绪：可在下方「更新内核」自动下载 xray";
            Changed?.Invoke();
            return;
        }

        // 路由规则引用 geoip/geosite，缺文件 xray 直接起不来——首次启动自动播种
        try
        {
            ProxyAssetUpdate.EnsureRules(_paths.ProxyDirectory, Download);
        }
        catch (Exception error)
        {
            Message = $"geo 规则下载失败：{error.Message}（检查网络或稍后再试）";
            Changed?.Invoke();
            return;
        }

        if (CurrentConfig() is not { } config) { Changed?.Invoke(); return; }
        _runner.Start(config);
    }

    public void StopEngine() => _runner.Stop();

    public void ToggleEngine()
    {
        if (IsEngineRunning) StopEngine();
        else StartEngine();
        Changed?.Invoke();
    }

    private void RestartEngine()
    {
        if (CurrentConfig() is not { } config) return;
        _runner.Update(config);
    }

    /// <summary>按当前模式生成配置。返回 null 表示前置不满足（已设置 Message）。</summary>
    private string? CurrentConfig()
    {
        var candidates = Library.Nodes.Where(n => n.BalancerCandidate).ToList();
        if (Library.Runtime.AutoSwitch)
        {
            if (candidates.Count == 0)
            {
                Message = "自动切换需至少勾选一个候选节点";
                return null;
            }
            var node = Library.ActiveNode ?? candidates[0];
            return XrayConfigCompiler.CompileJson(node, Library.Runtime, candidates);
        }

        if (Library.ActiveNode is not { } active)
        {
            Message = "先添加并选择一个节点";
            return null;
        }
        return XrayConfigCompiler.CompileJson(active, Library.Runtime);
    }

    // ---- 测延迟 / 更新 / 系统代理 ----

    /// <summary>经本地 HTTP 代理测一次延迟（阻塞，调用方放后台线程）。</summary>
    public (bool Ok, string Detail) TestLatency()
    {
        if (!IsEngineRunning) return (false, "先启动代理");
        return LatencyProbe.MeasureThroughProxy(Library.Runtime.HttpPort);
    }

    /// <summary>检查更新（网络，放后台线程）。返回 (内核当前, 内核最新, 规则当前, 规则最新)。</summary>
    public (string CoreCurrent, string? CoreLatest, string? RulesCurrent, string? RulesLatest) CheckUpdates()
    {
        var (core, rules) = ProxyAssetUpdate.CurrentVersions(_paths.ProxyDirectory);
        var (coreLatest, rulesLatest) = ProxyAssetUpdate.CheckLatest(url =>
        {
            using var client = new System.Net.Http.HttpClient
            {
                Timeout = TimeSpan.FromSeconds(30),
                DefaultRequestHeaders = { { "User-Agent", "Toolbox" } },
            };
            return client.GetByteArrayAsync(url).GetAwaiter().GetResult();
        });
        return (core, coreLatest, rules, rulesLatest);
    }

    public void ApplyCoreUpdate(string tag)
    {
        // Windows 下运行中的 xray 锁着 exe，必须先停
        StopEngine();
        ProxyAssetUpdate.ApplyCoreUpdate(tag, _paths.ProxyDirectory, Download);
        Message = $"内核已更新到 {tag}";
        Changed?.Invoke();
    }

    public void ApplyRulesUpdate(string tag)
    {
        ProxyAssetUpdate.ApplyRulesUpdate(tag, _paths.ProxyDirectory, Download);
        Message = $"规则库已更新到 {tag}";
        Changed?.Invoke();
    }

    private static byte[] Download(Uri url)
    {
        using var client = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        return client.GetByteArrayAsync(url).GetAwaiter().GetResult();
    }

    /// <summary>切换系统代理。需要引擎在跑（否则全系统流量指到一个死端口）。</summary>
    public string? ToggleSystemProxy()
    {
        if (SystemProxyOn)
        {
            if (SystemProxyWin.Disable() is { } error) return $"关闭系统代理失败：{error}";
            SystemProxyOn = false;
            Message = "已关闭系统代理";
        }
        else
        {
            if (!IsEngineRunning) return "请先启动代理内核";
            if (SystemProxyWin.Enable(Library.Runtime.HttpPort, Library.Runtime.SocksPort) is { } error)
                return $"设置系统代理失败：{error}";
            SystemProxyOn = true;
            Message = "已设为系统代理";
        }
        Changed?.Invoke();
        return null;
    }

    /// <summary>App 退出前调用：**必须**关掉系统代理，否则用户整个系统的流量会指向
    /// 一个已经死掉的本地端口，表现为「关掉 Toolbox 后全网打不开」。</summary>
    public void Shutdown()
    {
        _runner.Stop();
        if (SystemProxyOn)
        {
            SystemProxyWin.Disable();
            SystemProxyOn = false;
        }
    }

    private void Persist()
    {
        try { _store.Save(Library); }
        catch (Exception error) { _log($"代理库保存失败：{error.Message}"); }
    }
}
