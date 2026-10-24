using Toolbox.Core.Hosts;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class HostsCompilerTests
{
    private static readonly NamedRule Dev = new("开发", "127.0.0.1 dev.example.com\n");
    private static readonly NamedRule Api = new("接口", "10.0.0.2 api.example.com\n10.0.0.2 cdn.example.com\n");

    [Fact]
    public void AddsManagedBlockAndKeepsUserLines()
    {
        var current = "127.0.0.1 localhost\n# 用户手写\n";
        var result = RuleCompiler.Compile(new[] { Dev }, current);

        Assert.Contains("127.0.0.1 localhost", result.Content);
        Assert.Contains("# 用户手写", result.Content);
        Assert.Contains(RuleCompiler.BeginSentinel, result.Content);
        Assert.Contains(RuleCompiler.EndSentinel, result.Content);
        Assert.Contains("# ==== 开发 ====", result.Content);
        Assert.Contains("127.0.0.1 dev.example.com", result.Content);
        Assert.Equal(1, result.Stats.EnabledRuleCount);
        Assert.Equal(1, result.Stats.MappingCount);
        Assert.True(result.Content.IndexOf(RuleCompiler.BeginSentinel, StringComparison.Ordinal) <
                    result.Content.IndexOf(RuleCompiler.EndSentinel, StringComparison.Ordinal));
    }

    [Fact]
    public void ReplacesExistingManagedBlockInsteadOfAppending()
    {
        var first = RuleCompiler.Compile(new[] { Dev }, "127.0.0.1 localhost\n").Content;
        var second = RuleCompiler.Compile(new[] { Api }, first).Content;

        Assert.DoesNotContain("dev.example.com", second);
        Assert.Contains("api.example.com", second);
        Assert.Equal(1, CountOccurrences(second, RuleCompiler.BeginSentinel));
        Assert.Contains("127.0.0.1 localhost", second);
    }

    [Fact]
    public void RemovingAllRulesDropsBlockAndKeepsUserLines()
    {
        var withBlock = RuleCompiler.Compile(new[] { Dev }, "127.0.0.1 localhost\n").Content;
        var cleared = RuleCompiler.Compile(Array.Empty<NamedRule>(), withBlock);

        Assert.DoesNotContain(RuleCompiler.BeginSentinel, cleared.Content);
        Assert.Contains("127.0.0.1 localhost", cleared.Content);
        Assert.Equal(0, cleared.Stats.MappingCount);
    }

    [Fact]
    public void BrokenSentinelIsReportedNotGuessed()
    {
        var current = $"{RuleCompiler.BeginSentinel}\n127.0.0.1 a.com\n";
        var error = Assert.Throws<BrokenSentinelException>(() =>
            RuleCompiler.Compile(new[] { Dev }, current));
        Assert.Contains("缺少闭合标签", error.Message);

        var reversed = $"{RuleCompiler.EndSentinel}\n{RuleCompiler.BeginSentinel}\n";
        Assert.Throws<BrokenSentinelException>(() => RuleCompiler.Compile(new[] { Dev }, reversed));

        var duplicate = $"{RuleCompiler.BeginSentinel}\n{RuleCompiler.EndSentinel}\n" +
                        $"{RuleCompiler.BeginSentinel}\n{RuleCompiler.EndSentinel}\n";
        Assert.Throws<BrokenSentinelException>(() => RuleCompiler.Compile(new[] { Dev }, duplicate));
    }

    [Fact]
    public void NormalizesCrlfBomAndTrailingBlankLines()
    {
        var current = "\uFEFF127.0.0.1 localhost\r\n\r\n\r\n";
        var result = RuleCompiler.Compile(Array.Empty<NamedRule>(), current);

        Assert.DoesNotContain("\r", result.Content);
        Assert.DoesNotContain('\uFEFF', result.Content);
        Assert.EndsWith("\n", result.Content);
        Assert.DoesNotContain("\n\n", result.Content);
    }

    [Fact]
    public void ParsesMappingsToleratingCommentsAndMultipleDomains()
    {
        var mappings = RuleCompiler.ParseMappings(
            "127.0.0.1 a.com b.com # inline\n// 整行注释\nnot-an-ip c.com\n::1 v6.local\n");

        Assert.Equal(3, mappings.Count);
        Assert.Contains(new HostsMapping("127.0.0.1", "a.com"), mappings);
        Assert.Contains(new HostsMapping("127.0.0.1", "b.com"), mappings);
        Assert.Contains(new HostsMapping("::1", "v6.local"), mappings);
    }

    [Fact]
    public void ReportsConflictsOnlyWhenSameDomainPointsToDifferentIps()
    {
        var rules = new[]
        {
            new NamedRule("A", "1.1.1.1 same.com\n"),
            new NamedRule("B", "2.2.2.2 same.com\n"),
            new NamedRule("C", "3.3.3.3 other.com\n"),
        };
        var conflicts = RuleCompiler.Conflicts(rules);

        var conflict = Assert.Single(conflicts);
        Assert.Equal("same.com", conflict.Domain);
        Assert.Equal(new[] { "A", "B" }, conflict.Mappings.Select(m => m.RuleName));
    }

    [Fact]
    public void DuplicateSameIpAcrossRulesIsNotAConflict()
    {
        var rules = new[]
        {
            new NamedRule("A", "1.1.1.1 same.com\n"),
            new NamedRule("B", "1.1.1.1 same.com\n"),
        };
        Assert.Empty(RuleCompiler.Conflicts(rules));
    }

    [Fact]
    public void StarterLibraryHasOneDisabledExample()
    {
        var library = HostsLibrary.Starter();
        var rule = Assert.Single(library.AllRules);
        Assert.False(rule.Enabled);
        Assert.Equal(RuleKind.Inline, rule.Kind);
        Assert.Contains("dev.example.com", rule.Source);
    }

    private static int CountOccurrences(string text, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }
        return count;
    }
}
