using Toolbox.Core.Settings;
using Xunit;

namespace Toolbox.Core.Tests;

/// <summary>
/// BUG-008：软件更新段（对齐 Mac 的 UpdateSettings）。
/// 之前 Windows 只有孤立 updateUrl：无手动检查、无间隔、无代理/镜像，更新行为黑盒。
/// </summary>
public sealed class SoftwareUpdateSettingsTests
{
    [Fact]
    public void DefaultsMatchMacSemantics()
    {
        var s = new SoftwareUpdateSettings();
        Assert.True(s.AutoCheck);                       // 默认开（Mac 同）
        Assert.Equal(24, s.CheckIntervalHours);
        Assert.False(s.UseProxy);
        Assert.Equal(10809, s.ProxyPort);
        Assert.Equal("", s.GithubMirror);
    }

    [Fact]
    public void SettingsRoundTripKeepsUpdateSection()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"upd-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "settings.json");
            var settings = new AppSettings
            {
                UpdateUrl = "https://example.com/feed",
                Update = new SoftwareUpdateSettings
                {
                    AutoCheck = false,
                    CheckIntervalHours = 12,
                    UseProxy = true,
                    ProxyPort = 8080,
                    GithubMirror = "https://ghproxy.net/",
                },
            };
            new SettingsStore(file).Save(settings);

            var loaded = new SettingsStore(file).Load();
            Assert.Equal("https://example.com/feed", loaded.UpdateUrl);
            Assert.False(loaded.Update.AutoCheck);
            Assert.Equal(12, loaded.Update.CheckIntervalHours);
            Assert.True(loaded.Update.UseProxy);
            Assert.Equal(8080, loaded.Update.ProxyPort);
            Assert.Equal("https://ghproxy.net/", loaded.Update.GithubMirror);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public void OldSettingsJsonWithoutUpdateSectionFallsBackToDefaults()
    {
        // 老配置没有 update 段：不炸、回落默认（autoCheck=true 等）——
        // 老用户升级后「自动检查」默认开，符合预期。
        var dir = Path.Combine(Path.GetTempPath(), $"upd-old-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "settings.json");
            File.WriteAllText(file, "{ \"updateUrl\": \"https://example.com/x\", \"launchAtLogin\": true }");

            var loaded = new SettingsStore(file).Load();
            Assert.Equal("https://example.com/x", loaded.UpdateUrl);
            Assert.True(loaded.Update.AutoCheck);
            Assert.Equal(24, loaded.Update.CheckIntervalHours);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }
}

/// <summary>
/// 更新源 URL 派生规则（对齐 Mac AppUpdater.downloadURL 语义：镜像只作用于资产下载）。
/// </summary>
public sealed class UpdateFeedTests
{
    [Theory]
    [InlineData("https://github.com/a/b/releases/download/stable", "https://github.com/a/b/releases/download/stable/releases.win.json")]
    [InlineData("https://example.com/feed/", "https://example.com/feed/releases.win.json")]
    [InlineData("", "")]
    [InlineData("  ", "")]
    public void FeedUrlDerivation(string updateUrl, string expected)
        => Assert.Equal(expected, UpdateFeed.FeedUrl(updateUrl));

    [Theory]
    [InlineData("https://github.com/x/y/releases/download/v1/Toolbox-1-full.nupkg", "", "https://github.com/x/y/releases/download/v1/Toolbox-1-full.nupkg")]
    [InlineData("https://github.com/x/y/f.nupkg", "https://ghproxy.net/", "https://ghproxy.net/https://github.com/x/y/f.nupkg")]
    [InlineData("https://github.com/x/y/f.nupkg", "https://ghproxy.net", "https://ghproxy.net/https://github.com/x/y/f.nupkg")]
    [InlineData("https://github.com/x/y/f.nupkg", "   ", "https://github.com/x/y/f.nupkg")]
    [InlineData("", "https://ghproxy.net/", "")]
    public void MirrorOnlyAffectsAssetDownload(string assetUrl, string mirror, string expected)
        => Assert.Equal(expected, UpdateFeed.AssetDownloadUrl(assetUrl, mirror));

    [Theory]
    [InlineData(10809, 10809)]
    [InlineData(1, 1)]
    [InlineData(65535, 65535)]
    [InlineData(0, 10809)]
    [InlineData(70000, 10809)]
    [InlineData(-5, 10809)]
    public void ProxyPortNormalization(int port, int expected)
        => Assert.Equal(expected, UpdateFeed.NormalizeProxyPort(port));

    [Theory]
    [InlineData(1, 1)]
    [InlineData(24, 24)]
    [InlineData(168, 168)]
    [InlineData(0, 1)]
    [InlineData(-3, 1)]
    [InlineData(9999, 168)]
    public void IntervalNormalization(int hours, int expected)
        => Assert.Equal(expected, UpdateFeed.NormalizeIntervalHours(hours));
}
