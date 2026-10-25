using Xunit;
using Toolbox.Core.Proxy;

namespace Toolbox.Core.Tests;

public sealed class ProxyVersionTests
{
    [Theory]
    [InlineData("v26.3.27", new[] { 26L, 3, 27 })]
    [InlineData("202510010040", new[] { 202510010040L })]
    [InlineData("v1.2.3-beta", new[] { 1L, 2, 3 })]
    public void ComponentsExtractNumberGroups(string input, long[] expected)
    {
        Assert.Equal(expected, ProxyVersion.Components(input));
    }

    [Fact]
    public void MissingCurrentMeansUpdateNeeded()
    {
        Assert.True(ProxyVersion.IsNewer("v1.0.0", null));
        Assert.True(ProxyVersion.IsNewer("v1.0.0", ""));
        Assert.False(ProxyVersion.IsNewer(null, "v1.0.0"));
    }

    [Theory]
    [InlineData("v26.3.27", "v26.3.26", true)]
    [InlineData("v26.3.27", "v26.3.27", false)]
    [InlineData("v26.3", "v26.3.1", false)]      // 缺段补 0：26.3.0 < 26.3.1
    [InlineData("v27", "v26.9.9", true)]
    [InlineData("202510010040", "202509010000", true)]
    public void NewerComparesSegmentWise(string candidate, string current, bool expected)
    {
        Assert.Equal(expected, ProxyVersion.IsNewer(candidate, current));
    }
}
