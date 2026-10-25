using Xunit;
using Toolbox.Core.Proxy;

namespace Toolbox.Core.Tests;

public sealed class XrayBootstrapTests : IDisposable
{
    private readonly string _bundled = Path.Combine(Path.GetTempPath(), $"boot-bundled-{Guid.NewGuid():N}");
    private readonly string _work = Path.Combine(Path.GetTempPath(), $"boot-work-{Guid.NewGuid():N}");

    public void Dispose()
    {
        try { Directory.Delete(_bundled, true); } catch { }
        try { Directory.Delete(_work, true); } catch { }
    }

    private void SeedBundled(string version)
    {
        Directory.CreateDirectory(_bundled);
        File.WriteAllText(Path.Combine(_bundled, "version.txt"), version);
        File.WriteAllText(Path.Combine(_bundled, "xray.exe"), "CORE " + version);
        File.WriteAllText(Path.Combine(_bundled, "geoip.dat"), "geoip");
        File.WriteAllText(Path.Combine(_bundled, "geosite.dat"), "geosite");
    }

    [Theory]
    [InlineData("v2", null, false, true)]      // 缺已装版本 → 更新
    [InlineData("v2", "v1", true, true)]       // 随包比已装新 → 更新
    [InlineData("v1", "v2", true, false)]      // 已装更新 → 不冲回旧版
    [InlineData("v1", "v1", true, false)]      // 相同 → 不动
    [InlineData(null, null, false, false)]     // 随包没货 → 永不覆盖
    public void ShouldCopyCoreTruthTable(string? bundled, string? onDisk, bool present, bool expected)
    {
        Assert.Equal(expected, XrayBootstrap.ShouldCopyCore(bundled, onDisk, present));
    }

    [Fact]
    public void EnsureCopiesCoreAndSeedsRules()
    {
        SeedBundled("v1");
        var exe = XrayBootstrap.Ensure(_bundled, _work);

        Assert.Equal(Path.Combine(_work, "xray.exe"), exe);
        Assert.Equal("CORE v1", File.ReadAllText(exe));
        Assert.Equal("v1", File.ReadAllText(Path.Combine(_work, ".xray-version")).Trim());
        Assert.True(File.Exists(Path.Combine(_work, "geoip.dat")));
        Assert.True(File.Exists(Path.Combine(_work, "geosite.dat")));
    }

    /// <summary>更新器换过的新内核不能被旧随包版本冲回去。</summary>
    [Fact]
    public void EnsureKeepsNewerOnDiskCore()
    {
        SeedBundled("v1");
        XrayBootstrap.Ensure(_bundled, _work);

        File.WriteAllText(Path.Combine(_work, "xray.exe"), "CORE v9");
        File.WriteAllText(Path.Combine(_work, ".xray-version"), "v9");

        XrayBootstrap.Ensure(_bundled, _work);

        Assert.Equal("CORE v9", File.ReadAllText(Path.Combine(_work, "xray.exe")));
    }

    [Fact]
    public void ExistingWorkCoreAloneIsEnough()
    {
        Directory.CreateDirectory(_work);
        File.WriteAllText(Path.Combine(_work, "xray.exe"), "USER PLACED");

        var exe = XrayBootstrap.EnsureInstalled(_work, bundledDir: null);

        Assert.Equal("USER PLACED", File.ReadAllText(exe));
    }

    [Fact]
    public void MissingEverywhereThrowsWithGuidance()
    {
        Assert.Throws<BootstrapException>(() => XrayBootstrap.EnsureInstalled(_work, bundledDir: null));
    }
}

public sealed class ProxyStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"proxy-store-{Guid.NewGuid():N}");
    private string FilePath => Path.Combine(_dir, "nodes.json");

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    [Fact]
    public void RoundTripsLibrary()
    {
        var store = new ProxyStore(FilePath);
        var library = new ProxyLibrary { Runtime = new ProxyRuntimeSettings { SocksPort = 10808 } };
        var node = new ProxyNode { Name = "n1", Server = "h", Port = 1 };
        ProxyStore.Add(library, node);

        store.Save(library);
        var loaded = store.Load();

        Assert.Single(loaded.Nodes);
        Assert.Equal(node.Id, loaded.Nodes[0].Id);
        Assert.Equal(node.Id, loaded.ActiveNodeId);
        Assert.Equal(10808, loaded.Runtime.SocksPort);
    }

    [Fact]
    public void CorruptFileIsQuarantinedAndLoadFallsBack()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(FilePath, "{ not json");

        var loaded = new ProxyStore(FilePath).Load();

        Assert.Empty(loaded.Nodes);
        Assert.NotEmpty(Directory.GetFiles(_dir, "nodes.json.corrupt-*"));
    }

    [Fact]
    public void RemoveActiveNodePromotesFirst()
    {
        var library = new ProxyLibrary();
        var a = new ProxyNode { Name = "a" };
        var b = new ProxyNode { Name = "b" };
        ProxyStore.Add(library, a);
        ProxyStore.Add(library, b);

        ProxyStore.Remove(library, a.Id);

        Assert.Equal(b.Id, library.ActiveNodeId);
    }
}

/// <summary>生命周期用假进程同步测：启动/停止/崩溃退避/超限放弃。</summary>
public sealed class XrayRunnerTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"runner-{Guid.NewGuid():N}");
    private readonly List<FakeProcess> _spawned = [];

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    private XrayRunner NewRunner(int maxAttempts = 5)
    {
        return new XrayRunner(
            () =>
            {
                var p = new FakeProcess();
                _spawned.Add(p);
                return p;
            },
            Path.Combine(_dir, "config.json"),
            schedule: work => work(),      // 立即执行退避
            maxAttempts: maxAttempts);
    }

    [Fact]
    public void StartWritesConfigAndLaunches()
    {
        var runner = NewRunner();
        runner.Start("{}");

        Assert.Equal(XrayRunner.State.Running, runner.CurrentState);
        Assert.True(File.Exists(Path.Combine(_dir, "config.json")));
        Assert.Single(_spawned);
    }

    [Fact]
    public void StopKillsAndStaysStopped()
    {
        var runner = NewRunner();
        runner.Start("{}");
        runner.Stop();

        Assert.Equal(XrayRunner.State.Stopped, runner.CurrentState);
        Assert.True(_spawned[0].Killed);
    }

    [Fact]
    public void CrashTriggersBackoffRestart()
    {
        var runner = NewRunner();
        runner.Start("{}");

        _spawned[0].SimulateExit();

        Assert.Equal(XrayRunner.State.Running, runner.CurrentState);
        Assert.Equal(2, _spawned.Count);   // 退避后已重启
    }

    [Fact]
    public void IntentionalStopIsNotACrash()
    {
        var runner = NewRunner();
        runner.Start("{}");
        runner.Stop();

        // 迟到的退出回调（Kill 之后的竞态）不应触发重启
        _spawned[0].SimulateExit();

        Assert.Equal(XrayRunner.State.Stopped, runner.CurrentState);
        Assert.Single(_spawned);
    }

    [Fact]
    public void TooManyCrashesGivesUpWithFailed()
    {
        var runner = NewRunner(maxAttempts: 3);
        runner.Start("{}");

        for (var i = 0; i < 3; i++) _spawned[^1].SimulateExit();

        Assert.Equal(XrayRunner.State.Failed, runner.CurrentState);
        Assert.Equal(3, _spawned.Count);   // 首次 + 2 次退避，第 3 次崩溃后放弃
    }

    private sealed class FakeProcess : IXrayProcess
    {
        public bool IsRunning { get; private set; }
        public bool Killed { get; private set; }
        public Action? OnExit { get; set; }

        public void Launch() => IsRunning = true;

        public void Kill()
        {
            Killed = true;
            IsRunning = false;
        }

        public void SimulateExit()
        {
            IsRunning = false;
            OnExit?.Invoke();
        }
    }
}
