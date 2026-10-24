using Toolbox.Core.Infrastructure;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class AppPathsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "toolbox-paths-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch { }
    }

    private AppPaths NewPaths() =>
        new(Path.Combine(_root, "roaming"), Path.Combine(_root, "local"));

    [Fact]
    public void PathsMatchTheReadmeTable()
    {
        var paths = NewPaths();
        Assert.Equal(Path.Combine(paths.RoamingRoot, "settings.json"), paths.Settings);
        Assert.Equal(Path.Combine(paths.RoamingRoot, "hosts", "rules.json"), paths.HostsRules);
        Assert.Equal(Path.Combine(paths.RoamingRoot, "ai.key"), paths.AiKeyFile);
        Assert.Equal(Path.Combine(paths.LocalRoot, "clipboard.db"), paths.ClipboardDatabase);
        Assert.Equal(Path.Combine(paths.LocalRoot, "media"), paths.MediaDirectory);
        Assert.Equal(Path.Combine(paths.LocalRoot, "logs"), paths.LogsDirectory);
        Assert.Equal(Path.Combine(paths.LocalRoot, "probe.txt"), paths.ProbeReport);
    }

    /// <summary>设置走漫游目录、库和日志走本地目录：别让剪贴板数据库跟着漫游同步到处跑。</summary>
    [Fact]
    public void BulkyDataStaysOutOfTheRoamingRoot()
    {
        var paths = NewPaths();
        Assert.DoesNotContain(paths.RoamingRoot, paths.ClipboardDatabase);
        Assert.DoesNotContain(paths.RoamingRoot, paths.MediaDirectory);
        Assert.DoesNotContain(paths.RoamingRoot, paths.LogsDirectory);
    }

    [Fact]
    public void EnsureDirectoriesIsIdempotent()
    {
        var paths = NewPaths();
        paths.EnsureDirectories();
        paths.EnsureDirectories();

        Assert.True(Directory.Exists(paths.RoamingRoot));
        Assert.True(Directory.Exists(Path.GetDirectoryName(paths.HostsRules)));
        Assert.True(Directory.Exists(paths.MediaDirectory));
        Assert.True(Directory.Exists(paths.LogsDirectory));
    }

    [Fact]
    public void StandardPutsEverythingUnderAToolboxFolder()
    {
        var paths = AppPaths.Standard();
        Assert.Equal("Toolbox", Path.GetFileName(paths.RoamingRoot));
        Assert.Equal("Toolbox", Path.GetFileName(paths.LocalRoot));
    }
}
