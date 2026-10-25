using System.Text.Json;
using System.Text.Json.Serialization;

namespace Toolbox.Core.Settings;

[Flags]
public enum HotkeyModifiers
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Win = 8,
}

/// <summary>一条全局热键。Key 用 Win32 虚拟键码，序列化成 "Ctrl+Alt+V" 这样的文本。</summary>
public readonly record struct HotkeyGesture(HotkeyModifiers Modifiers, int VirtualKey)
{
    public bool IsEmpty => VirtualKey == 0;

    public override string ToString()
    {
        if (IsEmpty) return "未设置";
        var parts = new List<string>(4);
        if (Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
        if (Modifiers.HasFlag(HotkeyModifiers.Win)) parts.Add("Win");
        parts.Add(KeyName(VirtualKey));
        return string.Join("+", parts);
    }

    public static string KeyName(int vk) => vk switch
    {
        >= 0x41 and <= 0x5A => ((char)('A' + (vk - 0x41))).ToString(),
        >= 0x30 and <= 0x39 => ((char)('0' + (vk - 0x30))).ToString(),
        >= 0x70 and <= 0x87 => "F" + (vk - 0x6F),
        0x20 => "Space",
        0x0D => "Enter",
        0x1B => "Esc",
        0x09 => "Tab",
        0xC0 => "`",
        _ => "VK" + vk,
    };

    /// <summary>解析 "Ctrl+Alt+V" / "F8" / "Ctrl+Shift+F10"。失败返回 null。</summary>
    public static HotkeyGesture? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var mods = HotkeyModifiers.None;
        int vk = 0;
        foreach (var raw in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= HotkeyModifiers.Control; break;
                case "alt": mods |= HotkeyModifiers.Alt; break;
                case "shift": mods |= HotkeyModifiers.Shift; break;
                case "win" or "meta": mods |= HotkeyModifiers.Win; break;
                default:
                    if (raw.Length == 1 && char.IsAsciiLetter(raw[0]))
                        vk = char.ToUpperInvariant(raw[0]);
                    else if (raw.Length == 1 && char.IsAsciiDigit(raw[0]))
                        vk = raw[0];
                    else if (raw.Length is >= 2 and <= 3 && char.ToUpperInvariant(raw[0]) == 'F' &&
                             int.TryParse(raw[1..], out var n) && n is >= 1 and <= 24)
                        vk = 0x6F + n;
                    else if (raw.ToLowerInvariant() is "space" or "enter" or "esc" or "escape" or "tab" or "backtick")
                        vk = raw.ToLowerInvariant() switch
                        {
                            "space" => 0x20,
                            "enter" => 0x0D,
                            "esc" or "escape" => 0x1B,
                            "tab" => 0x09,
                            _ => 0xC0,
                        };
                    else
                        return null;
                    break;
            }
        }
        return vk == 0 ? null : new HotkeyGesture(mods, vk);
    }
}

public sealed class HotkeySettings
{
    public HotkeyGesture ClipboardPanel { get; set; } = new(HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x56);
    public HotkeyGesture Translation { get; set; } = new(HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x54);
    public HotkeyGesture HostsPanel { get; set; } = new(HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x48);
    public HotkeyGesture Screenshot { get; set; } = new(HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x41);
    /// <summary>F2：整屏直接钉图，不走选区（对齐 macOS 默认）。</summary>
    public HotkeyGesture CaptureFull { get; set; } = new(HotkeyModifiers.None, 0x71);
    /// <summary>F3：贴图穿透模式下的唯一救急出口，必须裸按就能触发。</summary>
    public HotkeyGesture KillAllPins { get; set; } = new(HotkeyModifiers.None, 0x72);

    public IEnumerable<(string Name, HotkeyGesture Gesture)> All()
    {
        yield return ("剪贴板历史", ClipboardPanel);
        yield return ("划词翻译", Translation);
        yield return ("Hosts 快切", HostsPanel);
        yield return ("区域截图", Screenshot);
        yield return ("全屏截图", CaptureFull);
        yield return ("关闭所有贴图", KillAllPins);
    }
}

public sealed class ClipboardSettings
{
    public int MaxItems { get; set; } = 500;
    public int MaxTextLength { get; set; } = 200_000;
    public int MaxImageMegabytes { get; set; } = 20;
    /// <summary>这些进程复制的内容不进历史（小写、不含 .exe）。</summary>
    public List<string> ExcludedProcesses { get; set; } = new() { "keepass", "1password", "bitwarden" };
    /// <summary>自己写回剪贴板后的忽略窗口，避免把粘贴出去的内容又采一遍。</summary>
    public int SelfWriteIgnoreMilliseconds { get; set; } = 800;
}

public sealed class CaptureSettings
{
    /// <summary>Windows 版默认走「选区后先标注」的流程，自动复制是可选的快照模式。</summary>
    public bool CopyAfterCapture { get; set; }
    public bool SaveToPictures { get; set; }
    public string SaveDirectory { get; set; } = "";
    public bool PinAfterCapture { get; set; }
    public int MosaicBlockSize { get; set; } = 12;
    /// <summary>贴图默认参与截图（用户可能就是想把贴图截进去）；关掉则截图前暂时隐藏贴图。</summary>
    public bool PinsParticipateInCapture { get; set; } = true;
}

public sealed class AppSettings
{
    public int Version { get; set; } = 1;
    public bool LaunchAtLogin { get; set; } = true;
    public HotkeySettings Hotkeys { get; set; } = new();
    public ClipboardSettings Clipboard { get; set; } = new();
    public CaptureSettings Capture { get; set; } = new();
    public Translation.TranslationSettings Translation { get; set; } = new();

    /// <summary>
    /// 自动更新源：一个能直接下载 Velopack 产物的 URL（含 releases.win.json）。
    /// 留空 = 不检查更新。GitHub 建议固定一个 tag（例如 stable），把 vpk 产物反复替换上去。
    /// </summary>
    public string UpdateUrl { get; set; } = "https://github.com/Think-Me/toolbox/releases/download/stable";
}

public static class SettingsJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase), new HotkeyGestureConverter() },
    };
}

/// <summary>"Ctrl+Alt+V" ↔ HotkeyGesture。老配置写坏了只丢这一项，不影响整份设置。</summary>
public sealed class HotkeyGestureConverter : JsonConverter<HotkeyGesture>
{
    public override HotkeyGesture Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String &&
            HotkeyGesture.Parse(reader.GetString()) is { } parsed)
            return parsed;
        if (reader.TokenType == JsonTokenType.StartObject)
        {
            using var doc = JsonDocument.ParseValue(ref reader);
            var mods = HotkeyModifiers.None;
            if (doc.RootElement.TryGetProperty("modifiers", out var m) && m.ValueKind == JsonValueKind.String)
                mods = Enum.TryParse<HotkeyModifiers>(m.GetString(), true, out var parsedMods) ? parsedMods : HotkeyModifiers.None;
            var vk = doc.RootElement.TryGetProperty("virtualKey", out var k) && k.TryGetInt32(out var v) ? v : 0;
            return new HotkeyGesture(mods, vk);
        }
        return default;
    }

    public override void Write(Utf8JsonWriter writer, HotkeyGesture value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}

public sealed class SettingsStore
{
    private readonly string _file;

    public SettingsStore(string file) => _file = file;

    public AppSettings Load()
    {
        try
        {
            if (!File.Exists(_file)) return new AppSettings();
            var json = File.ReadAllText(_file);
            return JsonSerializer.Deserialize<AppSettings>(json, SettingsJson.Options) ?? new AppSettings();
        }
        catch
        {
            // 坏文件不阻断启动：备份一份现场，再回落默认值。
            try { File.Copy(_file, _file + ".corrupt-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), true); } catch { }
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
        var tmp = _file + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(settings, SettingsJson.Options));
        File.Move(tmp, _file, true);
    }
}
