using System.IO;
using System.Windows;
using Toolbox.Core.Settings;
using Velopack;
using Velopack.Sources;

namespace Toolbox.App.Update;

/// <summary>
/// 自动更新（Velopack）。只有通过安装器安装的版本才会检查更新
/// （UpdateManager.IsInstalled，绿色目录/probe 调试一律跳过）。
/// 更新源来自 settings.json 的 updateUrl，留空 = 不检查。
/// 发现新版本后后台下载，等用户退出时自动应用（不打断正在用的功能）。
/// </summary>
internal sealed class UpdateService
{
    private readonly Func<string> _updateUrl;
    private readonly Action<string> _report;
    private readonly Action<UpdateManager, UpdateInfo> _applyOnExit;

    public UpdateService(Func<string> updateUrl, Action<string> report,
                         Action<UpdateManager, UpdateInfo> applyOnExit)
    {
        _updateUrl = updateUrl;
        _report = report;
        _applyOnExit = applyOnExit;
    }

    public void CheckForUpdates()
    {
        var url = _updateUrl();
        if (string.IsNullOrWhiteSpace(url)) return;

        Task.Run(async () =>
        {
            try
            {
                var manager = new UpdateManager(url);
                if (!manager.IsInstalled) return;   // 绿色目录运行，更新交给安装器

                var updateInfo = await manager.CheckForUpdatesAsync();
                if (updateInfo is null)
                {
                    _report("已是最新版本");
                    return;
                }

                var version = updateInfo.TargetFullRelease.Version;
                _report($"发现新版本 {version}，后台下载中…");
                await manager.DownloadUpdatesAsync(updateInfo);
                _applyOnExit(manager, updateInfo);
                _report($"新版本 {version} 已就绪，下次退出 Toolbox 时自动安装");
            }
            catch (Exception error)
            {
                // 更新检查失败静默降级：网络不通不该每次启动都弹窗
                _report($"检查更新失败：{error.Message}");
            }
        });
    }
}
