using System.Text.Json;
using Toolbox.Core.Settings;

namespace Toolbox.Core.Hosts;

/// <summary>
/// 规则库落盘（rules.json）。与 SettingsStore 同一套约定：
/// 原子写（tmp + Move），坏文件先备份现场再回落到示例库，绝不让坏 JSON 挡住启动。
/// </summary>
public sealed class HostsStore
{
    private readonly string _file;

    public HostsStore(string file) => _file = file;

    public HostsLibrary Load()
    {
        try
        {
            if (!File.Exists(_file)) return HostsLibrary.Starter();
            var json = File.ReadAllText(_file);
            return JsonSerializer.Deserialize<HostsLibrary>(json, Options) ?? HostsLibrary.Starter();
        }
        catch
        {
            try { File.Copy(_file, _file + ".corrupt-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), true); }
            catch { /* 连备份都失败就只能放弃 */ }
            return HostsLibrary.Starter();
        }
    }

    public void Save(HostsLibrary library)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
        var tmp = _file + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(library, Options));
        File.Move(tmp, _file, true);
    }

    private static JsonSerializerOptions Options => SettingsJson.Options;
}

public static class HostsLibraryExtensions
{
    /// <summary>
    /// 把规则库编译成完整 hosts 内容。总开关关掉 = 等于没有启用规则（摘掉托管块，用户行原样保留）。
    /// </summary>
    public static CompileResult Compile(this HostsLibrary library, string currentHosts) =>
        RuleCompiler.Compile(
            (library.ManagementOn
                ? library.EnabledRules
                : Enumerable.Empty<HostsRule>())
            .Select(r => new NamedRule(r.Name, r.EffectiveContent)),
            currentHosts);
}
