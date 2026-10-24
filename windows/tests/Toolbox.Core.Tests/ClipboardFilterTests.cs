using Toolbox.Core.Clipboard;
using Toolbox.Core.Settings;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class ClipboardFilterTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 24, 12, 0, 0, TimeSpan.Zero);

    private static ClipboardItem TextItem(string text, string? process = null) => new()
    {
        Kind = ClipboardKind.Text,
        Text = text,
        ByteLength = text.Length,
        SourceProcess = process,
        CreatedAt = Now.ToUnixTimeMilliseconds() / 1000.0,
        LastCopiedAt = Now.ToUnixTimeMilliseconds() / 1000.0,
    };

    [Fact]
    public void CapturesNormalText()
    {
        var filter = new ClipboardFilter(new ClipboardSettings());
        Assert.Equal(CaptureDecision.Capture, filter.Decide(TextItem("hello"), null, Now, null));
    }

    [Theory]
    [InlineData("KeePass")]
    [InlineData("KeePass.exe")]
    [InlineData(@"C:\Program Files\KeePass\KeePass.exe")]
    [InlineData("keepass")]
    public void IgnoresExcludedProcesses(string process)
    {
        var filter = new ClipboardFilter(new ClipboardSettings());
        Assert.Equal(CaptureDecision.Ignore,
            filter.Decide(TextItem("secret", process), null, Now, null));
    }

    [Fact]
    public void IgnoresOwnWriteInsideWindow()
    {
        var filter = new ClipboardFilter(new ClipboardSettings { SelfWriteIgnoreMilliseconds = 800 });
        Assert.Equal(CaptureDecision.Ignore,
            filter.Decide(TextItem("pasted"), null, Now, Now.AddMilliseconds(-300)));
        Assert.Equal(CaptureDecision.Capture,
            filter.Decide(TextItem("typed"), null, Now, Now.AddMilliseconds(-900)));
    }

    [Fact]
    public void IgnoresEmptyTextEmptyFileListAndOversizedPayloads()
    {
        var filter = new ClipboardFilter(new ClipboardSettings
        {
            MaxTextLength = 10,
            MaxImageMegabytes = 1,
        });

        Assert.Equal(CaptureDecision.Ignore, filter.Decide(TextItem(""), null, Now, null));
        Assert.Equal(CaptureDecision.Ignore, filter.Decide(TextItem("01234567890"), null, Now, null));
        Assert.Equal(CaptureDecision.Ignore, filter.Decide(new ClipboardItem
        {
            Kind = ClipboardKind.FileUrls,
            FilePaths = new List<string>(),
            ByteLength = 1,
        }, null, Now, null));
        Assert.Equal(CaptureDecision.Ignore, filter.Decide(new ClipboardItem
        {
            Kind = ClipboardKind.Image,
            MediaSha256 = "abc",
            ByteLength = 2 * 1024 * 1024,
        }, null, Now, null));
    }

    [Fact]
    public void MarksRepeatedCopyOfLatestAsDuplicate()
    {
        var filter = new ClipboardFilter(new ClipboardSettings());
        var latest = TextItem("same");
        var candidate = TextItem("same");

        Assert.Equal(CaptureDecision.DuplicateLatest, filter.Decide(candidate, latest, Now, null));
        Assert.Equal(CaptureDecision.Capture, filter.Decide(TextItem("other"), latest, Now, null));
    }

    [Fact]
    public void ImagesCompareByHashAndFilesByOrderedPaths()
    {
        var imageA = new ClipboardItem { Kind = ClipboardKind.Image, MediaSha256 = "aa" };
        var imageB = new ClipboardItem { Kind = ClipboardKind.Image, MediaSha256 = "aa" };
        Assert.True(ClipboardFilter.SameContent(imageA, imageB));

        var filesA = new ClipboardItem { Kind = ClipboardKind.FileUrls, FilePaths = ["a", "b"] };
        var filesB = new ClipboardItem { Kind = ClipboardKind.FileUrls, FilePaths = ["b", "a"] };
        Assert.False(ClipboardFilter.SameContent(filesA, filesB));
    }

    [Fact]
    public void PreviewFoldsNewlinesAndShortensLongText()
    {
        Assert.Equal("a b c", TextItem("a\nb\tc").DisplayPreview);
        var longText = new string('x', 200);
        Assert.Equal(120, TextItem(longText).DisplayPreview.Length);
        Assert.EndsWith("…", TextItem(longText).DisplayPreview);
    }
}
