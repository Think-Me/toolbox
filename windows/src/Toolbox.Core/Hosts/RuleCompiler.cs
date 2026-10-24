using System.Text.Json.Serialization;

namespace Toolbox.Core.Hosts;

public enum RuleKind
{
    Inline,
    LocalFile,
    Remote,
}

public sealed class HostsRule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public bool Enabled { get; set; }
    public RuleKind Kind { get; set; } = RuleKind.Inline;
    /// <summary>inline 的正文 / localFile 的路径 / remote 的 URL。</summary>
    public string Source { get; set; } = "";
    /// <summary>remote 规则上次抓到的内容。</summary>
    public string? CachedContent { get; set; }
    public DateTimeOffset? LastSyncAt { get; set; }
    public string? ETag { get; set; }
    public string? LastError { get; set; }

    [JsonIgnore]
    public string EffectiveContent => Kind switch
    {
        RuleKind.Inline => Source,
        RuleKind.LocalFile => TryReadFile(Source),
        RuleKind.Remote => CachedContent ?? "",
        _ => "",
    };

    private static string TryReadFile(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : ""; }
        catch { return ""; }
    }
}

public sealed class RuleGroup
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public bool Collapsed { get; set; }
    public List<HostsRule> Rules { get; set; } = new();
}

public sealed class HostsLibrary
{
    public int Version { get; set; } = 1;
    public bool ManagementOn { get; set; } = true;
    public List<RuleGroup> Groups { get; set; } = new();

    [JsonIgnore]
    public IEnumerable<HostsRule> AllRules => Groups.SelectMany(g => g.Rules);

    [JsonIgnore]
    public IEnumerable<HostsRule> EnabledRules => AllRules.Where(r => r.Enabled);

    public static HostsLibrary Starter() => new()
    {
        Groups =
        {
            new RuleGroup
            {
                Name = "示例",
                Rules =
                {
                    new HostsRule
                    {
                        Name = "本地开发",
                        Enabled = false,
                        Source = "127.0.0.1 dev.example.com\n",
                    },
                },
            },
        },
    };
}

public readonly record struct HostsMapping(string Ip, string Domain);

public sealed record NamedRule(string Name, string Content);

public sealed record ConflictSide(string RuleName, string Ip);

public sealed record DomainConflict(string Domain, IReadOnlyList<ConflictSide> Mappings);

public sealed record CompileStats(int EnabledRuleCount, int MappingCount);

public sealed record CompileResult(string Content, IReadOnlyList<DomainConflict> Conflicts, CompileStats Stats);

public sealed class BrokenSentinelException(string reason) : Exception(reason);

/// <summary>
/// 把启用的规则编译成完整 hosts 内容。只改自己哨兵之间的托管块，块外用户行原样保留。
/// 哨兵不配对时抛错，绝不猜范围（猜错会吞掉用户手写行）。
/// </summary>
public static class RuleCompiler
{
    public const string BeginSentinel = "# >>> Toolbox managed >>>";
    public const string EndSentinel = "# <<< Toolbox managed <<<";

    public static CompileResult Compile(IEnumerable<NamedRule> enabled, string currentHosts)
    {
        var rules = enabled.ToList();
        var lines = SplitLines(currentHosts);
        var keep = NonManagedLines(lines);

        var outText = string.Join("\n", TrimTrailingBlanks(keep));
        var mappingCount = 0;
        if (rules.Count > 0)
        {
            var body = "";
            foreach (var rule in rules)
            {
                var content = NormalizeContent(rule.Content);
                body += $"# ==== {rule.Name} ====\n";
                if (content.Length > 0) body += content;
                mappingCount += ParseMappings(rule.Content).Count;
            }
            outText += "\n\n" + BeginSentinel + "\n" + body + EndSentinel;
        }

        return new CompileResult(
            NormalizeDocument(outText),
            Conflicts(rules),
            new CompileStats(rules.Count, mappingCount));
    }

    public static IReadOnlyList<HostsMapping> ParseMappings(string content)
    {
        var result = new List<HostsMapping>();
        foreach (var raw in SplitLines(content))
        {
            var line = raw;
            foreach (var marker in new[] { "#", "//" })
            {
                var idx = line.IndexOf(marker, StringComparison.Ordinal);
                if (idx >= 0) line = line[..idx];
            }
            var tokens = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (tokens.Length < 2) continue;
            var ip = tokens[0];
            if (!LooksLikeIp(ip)) continue;
            foreach (var domain in tokens.Skip(1)) result.Add(new HostsMapping(ip, domain));
        }
        return result;
    }

    /// <summary>只判断“像不像 IP”，不做严格校验（与 macOS 版一致）。</summary>
    public static bool LooksLikeIp(string s)
    {
        if (s.Contains(':'))
            return s.Length >= 2 && s.All(c => Uri.IsHexDigit(c) || c == ':');
        var parts = s.Split('.');
        if (parts.Length != 4) return false;
        return parts.All(p => p.Length is > 0 and <= 3 && p.All(char.IsAsciiDigit));
    }

    public static IReadOnlyList<DomainConflict> Conflicts(IReadOnlyList<NamedRule> rules)
    {
        var byDomain = new Dictionary<string, List<ConflictSide>>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var rule in rules)
        {
            foreach (var mapping in ParseMappings(rule.Content))
            {
                if (!byDomain.TryGetValue(mapping.Domain, out var sides))
                {
                    sides = new List<ConflictSide>();
                    byDomain[mapping.Domain] = sides;
                    order.Add(mapping.Domain);
                }
                sides.Add(new ConflictSide(rule.Name, mapping.Ip));
            }
        }

        var conflicts = new List<DomainConflict>();
        foreach (var domain in order)
        {
            var sides = byDomain[domain];
            if (sides.Select(s => s.Ip).Distinct().Count() <= 1) continue;
            var seen = new HashSet<string>();
            var distinct = sides.Where(s => seen.Add($"{s.RuleName}|{s.Ip}")).ToList();
            if (distinct.Select(s => s.Ip).Distinct().Count() > 1)
                conflicts.Add(new DomainConflict(domain, distinct));
        }
        return conflicts;
    }

    private static IReadOnlyList<string> NonManagedLines(IReadOnlyList<string> lines)
    {
        var begins = Enumerable.Range(0, lines.Count)
            .Where(i => lines[i].Trim() == BeginSentinel).ToList();
        var ends = Enumerable.Range(0, lines.Count)
            .Where(i => lines[i].Trim() == EndSentinel).ToList();

        if (begins.Count == 0 && ends.Count == 0) return lines;
        if (begins.Count == 0) throw new BrokenSentinelException("发现闭合标签但缺少开始标签");
        if (ends.Count == 0) throw new BrokenSentinelException("发现开始标签但缺少闭合标签");
        if (begins.Count != 1 || ends.Count != 1)
            throw new BrokenSentinelException($"哨兵标签出现多次（{begins.Count}/{ends.Count}），无法确定块范围");
        if (begins[0] > ends[0])
            throw new BrokenSentinelException("闭合标签在开始标签之前");

        return lines.Where((_, i) => i < begins[0] || i > ends[0]).ToList();
    }

    private static string[] SplitLines(string s) =>
        s.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');

    private static string NormalizeContent(string s)
    {
        var lines = SplitLines(s).ToList();
        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[0])) lines.RemoveAt(0);
        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[^1])) lines.RemoveAt(lines.Count - 1);
        return lines.Count == 0 ? "" : string.Join("\n", lines) + "\n";
    }

    private static List<string> TrimTrailingBlanks(IReadOnlyList<string> lines)
    {
        var list = lines.ToList();
        while (list.Count > 0 && string.IsNullOrWhiteSpace(list[^1])) list.RemoveAt(list.Count - 1);
        return list;
    }

    private static string NormalizeDocument(string s)
    {
        var text = s.Replace("\r\n", "\n").Replace('\r', '\n');
        if (text.StartsWith('\uFEFF')) text = text[1..];
        while (text.EndsWith("\n\n", StringComparison.Ordinal)) text = text[..^1];
        if (!text.EndsWith('\n')) text += "\n";
        return text;
    }
}
