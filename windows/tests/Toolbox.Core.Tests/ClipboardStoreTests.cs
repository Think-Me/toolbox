using Toolbox.Core.Clipboard;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class ClipboardStoreTests : IDisposable
{
    private readonly string _dir;
    private readonly ClipboardStore _store;

    public ClipboardStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "toolbox-clip-" + Guid.NewGuid().ToString("N"));
        _store = new ClipboardStore(Path.Combine(_dir, "clipboard.db"), Path.Combine(_dir, "media"));
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, true); } catch { }
    }

    private static ClipboardItem Text(string text, double at) => new()
    {
        Kind = ClipboardKind.Text,
        Text = text,
        ByteLength = text.Length,
        SourceProcess = "notepad",
        CreatedAt = at,
        LastCopiedAt = at,
    };

    [Fact]
    public void AddsAndListsNewestFirst()
    {
        _store.Add(Text("one", 100));
        _store.Add(Text("two", 200));
        _store.Add(Text("three", 300));

        var items = _store.List();
        Assert.Equal(new[] { "three", "two", "one" }, items.Select(i => i.Text));
        Assert.Equal("three", _store.Latest()!.Text);
    }

    [Fact]
    public void ReAddingLatestBumpsCountInsteadOfDuplicating()
    {
        _store.Add(Text("same", 100));
        var again = _store.Add(Text("same", 200));

        var items = _store.List();
        Assert.Single(items);
        Assert.Equal(200, items[0].LastCopiedAt);
        Assert.Equal(2, items[0].CopyCount);
        Assert.Equal(again.Id, items[0].Id);
    }

    [Fact]
    public void PinnedItemsSortFirstAndSurvivePrune()
    {
        _store.Add(Text("old", 100));
        _store.Add(Text("mid", 200));
        _store.Add(Text("new", 300));
        var old = _store.List().Single(i => i.Text == "old");
        _store.SetPinned(old.Id, true);

        Assert.Equal("old", _store.List()[0].Text);

        Assert.Equal(1, _store.Prune(2));
        var remaining = _store.List();
        Assert.Equal(new[] { "old", "new" }, remaining.Select(i => i.Text));

        Assert.Equal(0, _store.Prune(1));
        Assert.Equal(2, _store.List().Count);
    }

    [Fact]
    public void ClearUnpinnedKeepsPinned()
    {
        _store.Add(Text("keep", 100));
        _store.Add(Text("drop", 200));
        _store.SetPinned(_store.List().Single(i => i.Text == "keep").Id, true);

        Assert.Equal(1, _store.ClearUnpinned());
        Assert.Single(_store.List());
        Assert.Equal("keep", _store.List()[0].Text);
    }

    [Fact]
    public void SearchEscapesLikeWildcards()
    {
        _store.Add(Text("100% real", 100));
        _store.Add(Text("100x real", 200));

        var results = _store.List("%");
        Assert.Single(results);
        Assert.Equal("100% real", results[0].Text);
    }

    [Fact]
    public void ImagesLiveInMediaDirectoryKeyedBySha()
    {
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 1, 2, 3 };
        var sha = _store.SaveImage(png);

        Assert.Equal(sha, ClipboardItem.Sha256Hex(png));
        Assert.Equal(png, _store.LoadImage(sha));
        Assert.True(File.Exists(Path.Combine(_dir, "media", sha + ".png")));
        Assert.Null(_store.LoadImage("missing"));
    }

    [Fact]
    public void FilePathsRoundTripUsingU2028Separator()
    {
        var paths = new List<string> { @"C:\a\one.txt", "C:\\b\\line\nbreak.txt" };
        _store.Add(new ClipboardItem
        {
            Kind = ClipboardKind.FileUrls,
            FilePaths = paths,
            Text = "one.txt",
            ByteLength = 3,
            CreatedAt = 100,
            LastCopiedAt = 100,
        });

        var loaded = Assert.Single(_store.List());
        Assert.Equal(paths, loaded.FilePaths);
        Assert.Equal("文件 ×2 one.txt", loaded.DisplayPreview);
    }

    [Fact]
    public void DeleteRemovesRow()
    {
        var item = _store.Add(Text("gone", 100));
        _store.Delete(item.Id);
        Assert.Empty(_store.List());
    }
}
