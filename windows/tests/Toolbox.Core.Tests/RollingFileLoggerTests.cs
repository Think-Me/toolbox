using Toolbox.Core.Infrastructure;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class RollingFileLoggerTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "toolbox-log-" + Guid.NewGuid().ToString("N"));
    private static readonly DateTimeOffset Noon = new(2026, 10, 24, 12, 0, 0, TimeSpan.FromHours(8));

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    private RollingFileLogger NewLogger(long maxBytes = 2_000_000, int keepFiles = 10) =>
        new(_dir, "app", maxBytes, keepFiles, () => Noon);

    [Fact]
    public void WritesTimestampAndLevel()
    {
        var logger = NewLogger();
        logger.Error("出错了");

        var text = File.ReadAllText(Path.Combine(_dir, "app-20261024.log"));
        Assert.StartsWith("[2026-10-24 12:00:00.000] [ERROR] ", text);
        Assert.Contains("出错了", text);
    }

    [Fact]
    public void AppendsInsteadOfTruncating()
    {
        var logger = NewLogger();
        logger.Info("第一条");
        logger.Info("第二条");

        var lines = File.ReadAllLines(Path.Combine(_dir, "app-20261024.log"));
        Assert.Equal(2, lines.Length);
    }

    [Fact]
    public void RollsToAnArchiveOnceTheFileIsTooBig()
    {
        var logger = NewLogger(maxBytes: 120);
        for (var i = 0; i < 6; i++) logger.Info("把文件撑过上限的一行日志");

        var files = Directory.GetFiles(_dir, "app-*.log");
        Assert.True(files.Length > 1, $"应当切分出新文件，实际只有 {files.Length} 个");
    }

    /// <summary>
    /// 保留策略只约束**归档**文件；滚动后当天文件会被重新建出来，所以磁盘上最多是 keepFiles + 1。
    /// </summary>
    [Fact]
    public void KeepsOnlyTheNewestArchives()
    {
        var logger = NewLogger(maxBytes: 100, keepFiles: 3);
        for (var i = 0; i < 15; i++) logger.Info("再写一行让它不断滚动");

        var all = Directory.GetFiles(_dir, "app-*.log");
        var archives = all.Where(path => Path.GetFileName(path) != "app-20261024.log").ToArray();

        Assert.InRange(archives.Length, 1, 3);
        Assert.True(all.Length <= 4, $"归档 3 份 + 当天 1 份，实际 {all.Length} 个");
    }

    /// <summary>日志写不进去不能反过来把 App 弄崩。</summary>
    [Fact]
    public void SwallowsWriteFailures()
    {
        var logger = new RollingFileLogger("Z:\\不存在的盘符\\logs", "app", clock: () => Noon);
        logger.Info("应该被静默丢弃");
    }
}
