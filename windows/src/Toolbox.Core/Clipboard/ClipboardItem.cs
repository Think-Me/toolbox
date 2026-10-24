using System.Security.Cryptography;

namespace Toolbox.Core.Clipboard;

public enum ClipboardKind
{
    Text,
    Image,
    FileUrls,
}

public sealed class ClipboardItem
{
    /// <summary>文件名里换行合法，用 U+2028 连接路径（与 macOS 版一致）。</summary>
    public const string UrlSeparator = "\u2028";

    public Guid Id { get; set; } = Guid.NewGuid();
    public ClipboardKind Kind { get; set; }
    public string? Text { get; set; }
    public string? MediaSha256 { get; set; }
    public List<string>? FilePaths { get; set; }
    public long ByteLength { get; set; }
    public int? PixelWidth { get; set; }
    public int? PixelHeight { get; set; }
    public string? SourceProcess { get; set; }
    public string? SourceAppName { get; set; }
    public bool Pinned { get; set; }
    public double CreatedAt { get; set; }
    public double LastCopiedAt { get; set; }
    public int CopyCount { get; set; } = 1;

    public string DisplayPreview
    {
        get
        {
            switch (Kind)
            {
                case ClipboardKind.Text:
                    var folded = (Text ?? "").Replace('\n', ' ').Replace('\t', ' ');
                    if (folded.Length == 0) return "";
                    return folded.Length <= 120 ? folded : folded[..119] + "…";
                case ClipboardKind.Image:
                    var size = PixelWidth is { } w && PixelHeight is { } h ? $" {w}×{h}" : "";
                    return $"图片{size}";
                case ClipboardKind.FileUrls:
                    var count = FilePaths?.Count ?? 0;
                    var first = FilePaths is { Count: > 0 } ? LastPathSegment(FilePaths[0]) : "";
                    return count <= 1 ? $"文件 {first}" : $"文件 ×{count} {first}";
                default:
                    return "";
            }
        }
    }

    public string? FilePathsJoined => FilePaths is { Count: > 0 } ? string.Join(UrlSeparator, FilePaths) : null;

    public static List<string> SplitPaths(string? joined) =>
        string.IsNullOrEmpty(joined)
            ? new List<string>()
            : joined.Split(UrlSeparator).Where(p => p.Length > 0).ToList();

    public static string Sha256Hex(ReadOnlySpan<byte> data) =>
        Convert.ToHexStringLower(SHA256.HashData(data));

    /// <summary>同时认 / 和 \ 两种分隔符：Windows 路径在 macOS 测试机上也要取对文件名。</summary>
    private static string LastPathSegment(string path)
    {
        var index = path.LastIndexOfAny(['/', '\\']);
        return index >= 0 ? path[(index + 1)..] : path;
    }
}

public static class ClipboardMedia
{
    public static string PathFor(string directory, string sha) =>
        Path.Combine(directory, sha + ".png");

    /// <summary>
    /// 删除数据库已经不引用的图片文件（淘汰/删除条目后留下的孤儿）。返回删除个数。
    /// 文件名就是 sha256，按文件名对照即可，不用读内容。
    /// </summary>
    public static int Cleanup(string directory, IEnumerable<string?> referencedShas)
    {
        if (!Directory.Exists(directory)) return 0;

        var keep = referencedShas
            .Where(sha => !string.IsNullOrEmpty(sha))
            .Select(sha => sha!)
            .ToHashSet(StringComparer.Ordinal);

        var removed = 0;
        foreach (var file in Directory.EnumerateFiles(directory, "*.png"))
        {
            if (keep.Contains(Path.GetFileNameWithoutExtension(file))) continue;
            try
            {
                File.Delete(file);
                removed++;
            }
            catch
            {
                // 被占用的文件下次启动再删，不值得为此中断
            }
        }
        return removed;
    }
}
