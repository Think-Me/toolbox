using Toolbox.Core.Clipboard;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class ClipboardListSelectionTests
{
    [Fact]
    public void EmptyListHasNoValidSelection()
    {
        var selection = new ClipboardListSelection(0);
        Assert.False(selection.IsValid);
        Assert.Equal(0, selection.Index);
    }

    [Fact]
    public void StartsOnTheFirstRow()
    {
        var selection = new ClipboardListSelection(5);
        Assert.True(selection.IsValid);
        Assert.Equal(0, selection.Index);
    }

    /// <summary>过滤后行数骤减时，旧 index 会越界并指向不存在的位置。</summary>
    [Fact]
    public void ShrinkingClampsToTheLastRow()
    {
        var selection = new ClipboardListSelection(10);
        selection.Select(9);
        selection.SetCount(3);

        Assert.Equal(2, selection.Index);
        Assert.True(selection.IsValid);
    }

    [Fact]
    public void ShrinkingToZeroResetsSafely()
    {
        var selection = new ClipboardListSelection(4);
        selection.Select(2);
        selection.SetCount(0);

        Assert.Equal(0, selection.Index);
        Assert.False(selection.IsValid);
    }

    /// <summary>换过滤词等于换了一批内容，停在原来的序号会让用户回车粘到不相关的东西。</summary>
    [Fact]
    public void ApplyingAFilterGoesBackToTheTop()
    {
        var selection = new ClipboardListSelection(10);
        selection.Select(7);
        selection.ApplyFilter(2);

        Assert.Equal(0, selection.Index);
    }

    [Theory]
    [InlineData(1, 1)]
    [InlineData(3, 3)]
    [InlineData(-1, 4)]
    [InlineData(-2, 3)]
    public void MoveWrapsAroundBothEnds(int delta, int expected)
    {
        var selection = new ClipboardListSelection(5);
        selection.Move(delta);
        Assert.Equal(expected, selection.Index);
    }

    [Fact]
    public void MoveOnEmptyListStaysAtZero()
    {
        var selection = new ClipboardListSelection(0);
        selection.Move(3);
        Assert.Equal(0, selection.Index);
    }

    [Theory]
    [InlineData(-5, 0)]
    [InlineData(0, 0)]
    [InlineData(3, 3)]
    [InlineData(99, 4)]
    public void SelectClampsIntoRange(int requested, int expected)
    {
        var selection = new ClipboardListSelection(5);
        selection.Select(requested);
        Assert.Equal(expected, selection.Index);
    }

    [Theory]
    [InlineData(1, 0)]
    [InlineData(3, 2)]
    [InlineData(4, null)]
    [InlineData(0, null)]
    public void QuickPickOnlyReturnsRowsThatExist(int digit, int? expected)
    {
        var selection = new ClipboardListSelection(3);
        Assert.Equal(expected, selection.QuickPick(digit));
    }

    [Fact]
    public void QuickPickOnEmptyListReturnsNull()
    {
        var selection = new ClipboardListSelection(0);
        Assert.Null(selection.QuickPick(1));
    }
}
