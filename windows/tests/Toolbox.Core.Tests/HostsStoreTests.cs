using Toolbox.Core.Hosts;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class HostsStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "toolbox-hosts-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    [Fact]
    public void MissingFileFallsBackToStarterLibrary()
    {
        var store = new HostsStore(Path.Combine(_dir, "rules.json"));
        var library = store.Load();

        Assert.True(library.ManagementOn);
        Assert.NotEmpty(library.Groups);   // 示例规则，让第一次打开不至于空白
    }

    [Fact]
    public void RoundTripsGroupsAndRules()
    {
        var store = new HostsStore(Path.Combine(_dir, "rules.json"));
        var library = new HostsLibrary
        {
            ManagementOn = false,
            Groups =
            {
                new RuleGroup
                {
                    Name = "公司",
                    Rules =
                    {
                        new HostsRule
                        {
                            Name = "内网", Enabled = true,
                            Kind = RuleKind.Inline, Source = "10.0.0.1 dev.local",
                        },
                        new HostsRule { Name = "远程源", Kind = RuleKind.Remote, Source = "https://x/a", ETag = "\"v1\"" },
                    },
                },
            },
        };
        store.Save(library);

        var loaded = store.Load();
        Assert.False(loaded.ManagementOn);
        var rule = Assert.Single(loaded.Groups[0].Rules.Take(1));
        Assert.Equal("内网", rule.Name);
        Assert.True(rule.Enabled);
        Assert.Equal("10.0.0.1 dev.local", rule.Source);
        Assert.Equal(RuleKind.Remote, loaded.Groups[0].Rules[1].Kind);
        Assert.Equal("\"v1\"", loaded.Groups[0].Rules[1].ETag);
    }

    [Fact]
    public void CorruptFileIsQuarantinedAndDefaultsReturn()
    {
        var path = Path.Combine(_dir, "rules.json");
        Directory.CreateDirectory(_dir);
        File.WriteAllText(path, "{ 不是 json");

        var library = new HostsStore(path).Load();

        Assert.True(library.ManagementOn);
        Assert.Single(Directory.GetFiles(_dir, "rules.json.corrupt-*"));
    }

    [Fact]
    public void CompileUsesOnlyEnabledRulesEffectiveContent()
    {
        var library = new HostsLibrary();
        library.Groups.Add(new RuleGroup
        {
            Name = "g",
            Rules =
            {
                new HostsRule { Name = "开", Enabled = true, Source = "1.2.3.4 a.test" },
                new HostsRule { Name = "关", Enabled = false, Source = "5.6.7.8 b.test" },
            },
        });

        var result = library.Compile("");

        Assert.Equal(1, result.Stats.EnabledRuleCount);
        Assert.Contains("1.2.3.4 a.test", result.Content);
        Assert.DoesNotContain("b.test", result.Content);
        Assert.Contains(RuleCompiler.BeginSentinel, result.Content);
    }

    [Fact]
    public void CompileKeepsUserLinesOutsideManagedBlock()
    {
        var library = new HostsLibrary();
        library.Groups.Add(new RuleGroup
        {
            Rules = { new HostsRule { Name = "r", Enabled = true, Source = "1.2.3.4 a.test" } },
        });

        var current = "127.0.0.1 localhost\n# >>> Toolbox managed >>>\n# 旧内容\n# <<< Toolbox managed <<<\n";
        var result = library.Compile(current);

        Assert.Contains("127.0.0.1 localhost", result.Content);
        Assert.DoesNotContain("# 旧内容", result.Content);
        Assert.Contains("# ==== r ====", result.Content);
    }

    [Fact]
    public void BrokenSentinelThrowsInsteadOfGuessing()
    {
        var library = new HostsLibrary();
        var current = "# <<< Toolbox managed <<<\n";

        Assert.Throws<BrokenSentinelException>(() => library.Compile(current));
    }

    /// <summary>总开关关掉 = 摘掉托管块：块内旧内容不再出现，用户自己的行保留。</summary>
    [Fact]
    public void ManagementOffRemovesTheManagedBlock()
    {
        var library = new HostsLibrary
        {
            ManagementOn = false,
            Groups =
            {
                new RuleGroup
                {
                    Rules = { new HostsRule { Name = "r", Enabled = true, Source = "1.2.3.4 a.test" } },
                },
            },
        };
        var current = "# >>> Toolbox managed >>>\n1.2.3.4 old.test\n# <<< Toolbox managed <<<\n";

        var result = library.Compile(current);

        Assert.DoesNotContain("old.test", result.Content);
        Assert.DoesNotContain("a.test", result.Content);
        Assert.Equal(0, result.Stats.EnabledRuleCount);
    }

    [Fact]
    public void CompileReportsDomainConflicts()
    {
        var library = new HostsLibrary();
        library.Groups.Add(new RuleGroup
        {
            Rules =
            {
                new HostsRule { Name = "规则一", Enabled = true, Source = "1.2.3.4 a.test" },
                new HostsRule { Name = "规则二", Enabled = true, Source = "5.6.7.8 a.test" },
            },
        });

        var result = library.Compile("");
        var conflict = Assert.Single(result.Conflicts);
        Assert.Equal("a.test", conflict.Domain);
        Assert.Equal(2, conflict.Mappings.Count);
    }
}
