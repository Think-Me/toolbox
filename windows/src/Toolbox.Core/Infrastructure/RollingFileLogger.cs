namespace Toolbox.Core.Infrastructure;

/// <summary>
/// 极简滚动日志。崩溃现场的日志比功能日志更重要，所以这里每次写入都直接落盘并关闭文件
/// —— 进程被强杀也不会丢掉最后一行，因此不提供 Flush()。
/// 记日志本身失败时静默丢弃：日志故障不能变成新的故障。
/// </summary>
public sealed class RollingFileLogger
{
    private readonly object _gate = new();
    private readonly string _directory;
    private readonly string _prefix;
    private readonly long _maxBytes;
    private readonly int _keepFiles;
    private readonly Func<DateTimeOffset> _clock;

    /// <param name="clock">只为测试注入；正常运行时跟随系统时钟。</param>
    public RollingFileLogger(string directory, string prefix = "app", long maxBytes = 2_000_000,
                             int keepFiles = 10, Func<DateTimeOffset>? clock = null)
    {
        _directory = directory;
        _prefix = prefix;
        _maxBytes = maxBytes;
        _keepFiles = keepFiles;
        _clock = clock ?? (() => DateTimeOffset.Now);
        Prune();
    }

    public void Info(string message) => Write("INFO", message);

    public void Error(string message) => Write("ERROR", message);

    public void Write(string level, string message)
    {
        var now = _clock();
        var line = $"[{now:yyyy-MM-dd HH:mm:ss.fff}] [{level}] {message}{Environment.NewLine}";
        lock (_gate)
        {
            try
            {
                Directory.CreateDirectory(_directory);
                var file = PathFor(now);
                File.AppendAllText(file, line);
                if (new FileInfo(file).Length >= _maxBytes) Roll(file, now);
            }
            catch
            {
                // 见类型注释：故意吞掉。
            }
        }
    }

    private string PathFor(DateTimeOffset stamp) =>
        Path.Combine(_directory, $"{_prefix}-{stamp:yyyyMMdd}.log");

    /// <summary>当天文件超限就改名归档，下一次写入会重新建当天的文件。</summary>
    private void Roll(string file, DateTimeOffset stamp)
    {
        var stem = $"{_prefix}-{stamp:yyyyMMdd}-{stamp:HHmmss}";
        var target = Path.Combine(_directory, stem + ".log");
        for (var i = 2; File.Exists(target); i++)
            target = Path.Combine(_directory, $"{stem}-{i}.log");
        File.Move(file, target);
        Prune();
    }

    /// <summary>只保留最新若干份。按修改时间排序，同名时间戳时用文件名兜底，避免删掉刚写的那个。</summary>
    private void Prune()
    {
        try
        {
            var files = Directory.GetFiles(_directory, _prefix + "-*.log")
                .Select(path => new FileInfo(path))
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .ThenByDescending(f => f.Name, StringComparer.Ordinal)
                .ToList();
            foreach (var stale in files.Skip(_keepFiles)) stale.Delete();
        }
        catch
        {
            // 同上，吞掉。
        }
    }
}
