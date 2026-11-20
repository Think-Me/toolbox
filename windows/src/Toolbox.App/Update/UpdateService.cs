using System.IO;
using System.Net;
using System.Net.Http;
using System.Windows;
using Toolbox.Core.Settings;
using Velopack;
using Velopack.Sources;

namespace Toolbox.App.Update;

/// <summary>
/// 软件更新服务（BUG-008：从「启动后台查一次」升级为完整能力，对齐 Mac SoftwareUpdateModel）：
///  - 手动「检查更新」（UI 触发，报告状态）
///  - 手动「下载并安装」（下载 → stage → 退出时应用）
///  - 定时自动检查（CheckIntervalHours，对齐 Mac）
///  - 检查/下载可走本地 HTTP 代理 + 加速镜像（对齐 Mac 的 useProxy/githubMirror）
///
/// 仍然只对安装版生效（UpdateManager.IsInstalled；绿色目录/调试跳过）。
/// 应用更新的时机语义保持 BUG-001 的修复：WaitExitThenApplyUpdates——
/// stage 之后 App 继续服务，退出时才换版本，绝不硬重启。
/// </summary>
internal sealed class UpdateService : IDisposable
{
    private readonly Func<string> _updateUrl;
    private readonly Func<SoftwareUpdateSettings> _settings;
    private readonly Action<string> _report;
    private readonly Action<UpdateManager, UpdateInfo> _applyOnExit;
    private readonly Action _persistSettings;
    private readonly System.Windows.Threading.DispatcherTimer? _timer;

    /// <summary>手动「下载并安装」的可用性状态（UI 绑定用）。</summary>
    public UpdateInfo? PendingInstall { get; private set; }
    public bool IsBusy { get; private set; }

    public event Action<string>? StatusReported;
    public event Action? Changed;

    /// <summary>报告一条状态：托盘气泡（ReportStatus）+ UI 状态框（StatusReported）双通道。</summary>
    private void Report(string message)
    {
        _report(message);
        StatusReported?.Invoke(message);
    }

    public UpdateService(Func<string> updateUrl, Func<SoftwareUpdateSettings> settings,
                         Action<string> report,
                         Action<UpdateManager, UpdateInfo> applyOnExit,
                         Action persistSettings)
    {
        _updateUrl = updateUrl;
        _settings = settings;
        _report = report;
        _applyOnExit = applyOnExit;
        _persistSettings = persistSettings;
        _timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromHours(UpdateFeed.NormalizeIntervalHours(settings().CheckIntervalHours)),
        };
        _timer.Tick += (_, _) => CheckForUpdates(automatic: true);
    }

    /// <summary>启动时调用：按设置决定要不要自动检查 + 起定时器。</summary>
    public void Start()
    {
        if (!_settings().AutoCheck) return;
        CheckForUpdates(automatic: true);
        _timer?.Start();
    }

    /// <summary>设置变化（间隔/开关）后重启定时器。</summary>
    public void RefreshTimer()
    {
        _timer?.Stop();
        if (_settings().AutoCheck)
        {
            _timer.Interval = TimeSpan.FromHours(UpdateFeed.NormalizeIntervalHours(_settings().CheckIntervalHours));
            _timer.Start();
        }
    }

    /// <summary>
    /// 手动检查（UI 按钮）或自动检查（定时器/启动）。
    /// 自动检查保持老语义：网络失败静默（不打扰）；手动检查把失败也报给用户。
    /// </summary>
    public void CheckForUpdates(bool automatic = false)
    {
        var url = _updateUrl();
        if (string.IsNullOrWhiteSpace(url))
        {
            if (!automatic) _report("更新源为空：settings.json 的 updateUrl 未配置，不检查更新");
            return;
        }

        if (IsBusy) return;
        IsBusy = true;
        Changed?.Invoke();

        Task.Run(async () =>
        {
            try
            {
                var manager = CreateManager(url, _settings());
                if (!manager.IsInstalled)
                {
                    // 绿色目录/调试运行：Velopack 只能更新安装版。手动检查给用户明确说法
                    //（自动检查保持静默），并提供手动下载出口——死按钮最伤人。
                    if (!automatic) OnUi(() => Report("当前是绿色目录运行，应用内更新不可用。请用安装版（Setup.exe），或「手动下载」获取新版"));
                    return;
                }

                var updateInfo = await manager.CheckForUpdatesAsync();
                if (updateInfo is null)
                {
                    if (!automatic) OnUi(() => Report("已是最新版本"));
                    return;
                }

                var version = updateInfo.TargetFullRelease.Version;
                OnUi(() =>
                {
                    PendingInstall = updateInfo;
                    _report($"发现新版本 {version}。可点「下载并安装」，或保持现状——退出 Toolbox 时也会自动应用已下载的更新");
                });
            }
            catch (Exception error)
            {
                // 自动检查失败静默降级：网络不该每次启动都弹窗（老语义，保留）
                if (!automatic) OnUi(() => Report($"检查更新失败：{error.Message}"));
            }
            finally
            {
                OnUi(() =>
                {
                    IsBusy = false;
                    Changed?.Invoke();
                });
            }
        });
    }

    /// <summary>
    /// 手动「下载并安装」：下载 → stage（退出时应用）。
    /// 下载进度通过 _report 反馈百分比。
    /// </summary>
    public void DownloadAndInstall()
    {
        var url = _updateUrl();
        if (string.IsNullOrWhiteSpace(url) || PendingInstall is null || IsBusy) return;
        IsBusy = true;
        Changed?.Invoke();

        Task.Run(async () =>
        {
            try
            {
                var manager = CreateManager(url, _settings());
                var version = PendingInstall.TargetFullRelease.Version;
                OnUi(() => Report($"新版本 {version} 后台下载中…"));
                await manager.DownloadUpdatesAsync(PendingInstall, progress: p =>
                    OnUi(() => Report($"下载中… {p}%")));
                _applyOnExit(manager, PendingInstall);
                OnUi(() => Report($"新版本 {version} 已就绪，下次退出 Toolbox 时自动安装"));
            }
            catch (Exception error)
            {
                OnUi(() => Report($"下载失败：{error.Message}"));
            }
            finally
            {
                OnUi(() =>
                {
                    IsBusy = false;
                    Changed?.Invoke();
                });
            }
        });
    }

    /// <summary>后台线程的 UI 反馈一律调度回 UI 线程（Task.Run 里直接触 UI 会跨线程访问 DispatcherObject）。</summary>
    private static void OnUi(Action action) =>
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(action);

    /// <summary>打开 releases 页面（「手动下载」按钮；浏览器自行处理网络）。</summary>
    public void OpenReleasesPage() =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "https://github.com/Think-Me/toolbox/releases/latest",
            UseShellExecute = true,
        });

    /// <summary>
    /// 构造 UpdateManager。两种路径：
    ///  - http(s)：用 SimpleWebSource + ProxiedFileDownloader（代理语义对齐 Mac：useProxy/proxyPort
    ///    覆盖 feed 探测与资产下载；Velopack 自带的下载器不接受自定义 HttpClient）。
    ///  - 本地目录/文件路径（开发调试用本地 feed）：直接用字符串构造（Velopack 对本地路径
    ///    有专门处理，SimpleWebSource 不认——实测 UpdateManager(string) 才支持）。
    /// </summary>
    private static UpdateManager CreateManager(string url, SoftwareUpdateSettings settings)
    {
        if (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            var port = UpdateFeed.NormalizeProxyPort(settings.ProxyPort);
            var downloader = new ProxiedFileDownloader(settings.UseProxy, port);
            return new UpdateManager(new SimpleWebSource(url, downloader));
        }
        return new UpdateManager(url);
    }

    public void Dispose()
    {
        _timer?.Stop();
    }
}
