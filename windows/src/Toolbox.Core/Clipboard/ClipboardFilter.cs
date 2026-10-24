using Toolbox.Core.Settings;

namespace Toolbox.Core.Clipboard;

public enum CaptureDecision
{
    Capture,
    /// <summary>与最近一条完全相同：不新增记录，只把它的 lastCopiedAt/copyCount 往前推。</summary>
    DuplicateLatest,
    Ignore,
}

/// <summary>采集侧的策略判定，和 Win32 剪贴板读取分开，便于单测。</summary>
public sealed class ClipboardFilter(ClipboardSettings settings)
{
    private readonly HashSet<string> _excluded = new(
        settings.ExcludedProcesses
            .Select(NormalizeProcess)
            .Where(s => s.Length > 0),
        StringComparer.OrdinalIgnoreCase);

    public ClipboardSettings Settings => settings;

    public static string NormalizeProcess(string? process)
    {
        if (string.IsNullOrWhiteSpace(process)) return "";
        var name = process.Trim();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        var slash = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
        if (slash >= 0) name = name[(slash + 1)..];
        return name;
    }

    public bool IsExcludedSource(string? process) =>
        _excluded.Contains(NormalizeProcess(process));

    public bool IsSelfWrite(DateTimeOffset now, DateTimeOffset? lastSelfWriteAt)
    {
        if (lastSelfWriteAt is not { } at) return false;
        var elapsed = (now - at).TotalMilliseconds;
        return elapsed >= 0 && elapsed <= settings.SelfWriteIgnoreMilliseconds;
    }

    public bool IsTooLarge(ClipboardKind kind, int byteLength, int? pixelWidth = null, int? pixelHeight = null)
    {
        return kind switch
        {
            ClipboardKind.Text => byteLength > settings.MaxTextLength,
            ClipboardKind.Image => byteLength > settings.MaxImageMegabytes * 1024L * 1024L,
            _ => false,
        };
    }

    public CaptureDecision Decide(ClipboardItem candidate, ClipboardItem? latest, DateTimeOffset now,
        DateTimeOffset? lastSelfWriteAt)
    {
        if (IsSelfWrite(now, lastSelfWriteAt)) return CaptureDecision.Ignore;
        if (IsExcludedSource(candidate.SourceProcess)) return CaptureDecision.Ignore;
        if (candidate.Kind == ClipboardKind.Text && string.IsNullOrEmpty(candidate.Text)) return CaptureDecision.Ignore;
        if (candidate.Kind == ClipboardKind.FileUrls && candidate.FilePaths is not { Count: > 0 })
            return CaptureDecision.Ignore;
        if (IsTooLarge(candidate.Kind, (int)Math.Min(int.MaxValue, candidate.ByteLength),
                candidate.PixelWidth, candidate.PixelHeight))
            return CaptureDecision.Ignore;

        if (latest is not null && SameContent(latest, candidate)) return CaptureDecision.DuplicateLatest;
        return CaptureDecision.Capture;
    }

    public static bool SameContent(ClipboardItem a, ClipboardItem b)
    {
        if (a.Kind != b.Kind) return false;
        return a.Kind switch
        {
            ClipboardKind.Text => string.Equals(a.Text, b.Text, StringComparison.Ordinal),
            ClipboardKind.Image => string.Equals(a.MediaSha256, b.MediaSha256, StringComparison.Ordinal),
            ClipboardKind.FileUrls => (a.FilePaths ?? new()).SequenceEqual(b.FilePaths ?? new(), StringComparer.Ordinal),
            _ => false,
        };
    }
}
