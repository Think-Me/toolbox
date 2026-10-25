using System.Text.Json;
using Toolbox.Core.Settings;

namespace Toolbox.Core.Proxy;

/// <summary>
/// 代理库读写。仿 HostsStore：存在自家可写目录，原子写；
/// 坏文件走「隔离副本 + 回落空库」，绝不因为 nodes.json 坏了而打不开设置页。
/// </summary>
public sealed class ProxyStore
{
    private readonly string _file;

    public ProxyStore(string file) => _file = file;

    public ProxyLibrary Load()
    {
        try
        {
            if (!File.Exists(_file)) return new ProxyLibrary();
            var json = File.ReadAllText(_file);
            return JsonSerializer.Deserialize<ProxyLibrary>(json, SettingsJson.Options) ?? new ProxyLibrary();
        }
        catch
        {
            try { File.Copy(_file, _file + ".corrupt-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), true); }
            catch { /* 连备份都失败就只能放弃 */ }
            return new ProxyLibrary();
        }
    }

    public void Save(ProxyLibrary library)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
        var tmp = _file + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(library, SettingsJson.Options));
        File.Move(tmp, _file, true);
    }

    // ---- 增删改（原地改 library，由调用方落盘，便于上层统一 save） ----

    public static void Add(ProxyLibrary library, ProxyNode node)
    {
        library.Nodes.Add(node);
        library.ActiveNodeId ??= node.Id;   // 第一个自动选中
    }

    public static void Remove(ProxyLibrary library, Guid id)
    {
        library.Nodes.RemoveAll(n => n.Id == id);
        if (library.ActiveNodeId == id) library.ActiveNodeId = library.Nodes.FirstOrDefault()?.Id;
    }

    public static void SetActive(ProxyLibrary library, Guid? id) => library.ActiveNodeId = id;
}
