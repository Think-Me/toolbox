using System.Text.Json;
using Toolbox.Core.Settings;
using Toolbox.Core.Translation;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class SettingsTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "toolbox-tests-" + Guid.NewGuid().ToString("N"));

    public SettingsTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    [Theory]
    [InlineData("Ctrl+Alt+V", HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x56)]
    [InlineData("ctrl+shift+f10", HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x79)]
    [InlineData("Win+Space", HotkeyModifiers.Win, 0x20)]
    [InlineData("F8", HotkeyModifiers.None, 0x77)]
    public void ParsesHotkeyText(string text, HotkeyModifiers modifiers, int virtualKey)
    {
        var parsed = HotkeyGesture.Parse(text);
        Assert.NotNull(parsed);
        Assert.Equal(modifiers, parsed!.Value.Modifiers);
        Assert.Equal(virtualKey, parsed.Value.VirtualKey);
    }

    [Theory]
    [InlineData("")]
    [InlineData("Ctrl+")]
    [InlineData("Hyper+V")]
    [InlineData("F25")]
    public void RejectsInvalidHotkeyText(string text) => Assert.Null(HotkeyGesture.Parse(text));

    [Fact]
    public void FormatsHotkeyInStableOrder()
    {
        var gesture = new HotkeyGesture(
            HotkeyModifiers.Shift | HotkeyModifiers.Win | HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x41);
        Assert.Equal("Ctrl+Alt+Shift+Win+A", gesture.ToString());
    }

    [Fact]
    public void SettingsRoundTripKeepsHotkeysAndTranslation()
    {
        var store = new SettingsStore(Path.Combine(_dir, "settings.json"));
        var settings = new AppSettings
        {
            LaunchAtLogin = false,
            Hotkeys = { Screenshot = new HotkeyGesture(HotkeyModifiers.Control, 0x51) },
            Translation = { Engine = TranslationEngine.Google, TargetLanguage = "ja", ProxyPort = 7890 },
        };
        store.Save(settings);

        var loaded = store.Load();
        Assert.False(loaded.LaunchAtLogin);
        Assert.Equal(new HotkeyGesture(HotkeyModifiers.Control, 0x51), loaded.Hotkeys.Screenshot);
        Assert.Equal(TranslationEngine.Google, loaded.Translation.Engine);
        Assert.Equal("ja", loaded.Translation.TargetLanguage);
        Assert.Equal(7890, loaded.Translation.ProxyPort);
    }

    [Fact]
    public void UnknownEngineFallsBackToAutoWithoutLosingOtherFields()
    {
        var json = """{"engine":"apple","targetLanguage":"ja"}""";
        var settings = JsonSerializer.Deserialize<TranslationSettings>(json, SettingsJson.Options);
        Assert.NotNull(settings);
        Assert.Equal(TranslationEngine.Auto, settings!.Engine);
        Assert.Equal("ja", settings.TargetLanguage);
        Assert.Equal(10809, settings.ProxyPort);
    }

    [Fact]
    public void MissingTranslationSectionUsesDefaults()
    {
        var json = """{"launchAtLogin":false}""";
        var settings = JsonSerializer.Deserialize<AppSettings>(json, SettingsJson.Options);
        Assert.NotNull(settings);
        Assert.Equal(TranslationEngine.Auto, settings!.Translation.Engine);
        Assert.Equal("zh-Hans", settings.Translation.TargetLanguage);
        Assert.False(settings.LaunchAtLogin);
    }

    [Fact]
    public void CorruptFileFallsBackToDefaultsAndKeepsBackup()
    {
        var path = Path.Combine(_dir, "settings.json");
        File.WriteAllText(path, "{ not json");
        var loaded = new SettingsStore(path).Load();
        Assert.Equal("zh-Hans", loaded.Translation.TargetLanguage);
        Assert.Single(Directory.GetFiles(_dir, "settings.json.corrupt-*"));
    }

    [Fact]
    public void ApiKeyIsNotSerialized()
    {
        var settings = new TranslationSettings { AiApiKey = "sk-secret" };
        var json = JsonSerializer.Serialize(settings, SettingsJson.Options);
        Assert.DoesNotContain("sk-secret", json);
    }
}
