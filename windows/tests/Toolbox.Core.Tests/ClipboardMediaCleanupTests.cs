using Toolbox.Core.Clipboard;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class ClipboardMediaCleanupTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "toolbox-media-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    private string WriteFile(string sha)
    {
        Directory.CreateDirectory(_dir);
        var path = ClipboardMedia.PathFor(_dir, sha);
        File.WriteAllBytes(path, [1, 2, 3]);
        return path;
    }

    [Fact]
    public void DeletesOrphanedFilesAndKeepsReferencedOnes()
    {
        var referenced = WriteFile("aaaa");
        var orphaned = WriteFile("bbbb");

        var removed = ClipboardMedia.Cleanup(_dir, ["aaaa"]);

        Assert.Equal(1, removed);
        Assert.True(File.Exists(referenced));
        Assert.False(File.Exists(orphaned));
    }

    [Fact]
    public void NullEntriesAreIgnored()
    {
        WriteFile("aaaa");
        var removed = ClipboardMedia.Cleanup(_dir, new string?[] { "aaaa", null });

        Assert.Equal(0, removed);
        Assert.True(File.Exists(ClipboardMedia.PathFor(_dir, "aaaa")));
    }

    [Fact]
    public void MissingDirectoryRemovesNothing()
    {
        Assert.Equal(0, ClipboardMedia.Cleanup(Path.Combine(_dir, "不存在"), ["a"]));
    }

    [Fact]
    public void EmptyReferenceListClearsEverything()
    {
        WriteFile("aaaa");
        WriteFile("bbbb");

        Assert.Equal(2, ClipboardMedia.Cleanup(_dir, []));
        Assert.Empty(Directory.GetFiles(_dir));
    }
}
