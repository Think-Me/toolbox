using System.IO;

namespace Toolbox.App.Diagnostics;

/// <summary>
/// `--probe` 的输出。WinExe 没有控制台，所以只能落文件、用退出码表达成败。
/// 目的：让"托盘挂上了没、热键注册成功没"这类只有交互桌面才知道的事可以被脚本验证，
/// 而不是只能靠人眼看托盘。
/// </summary>
internal sealed class ProbeReport
{
    private readonly List<string> _lines = [];
    private readonly List<string> _failures = [];

    public bool Ok => _failures.Count == 0;

    public void Line(string text) => _lines.Add(text);

    public void Fail(string text)
    {
        _failures.Add(text);
        _lines.Add("FAIL " + text);
    }

    public void Write(string path)
    {
        _lines.Add(Ok ? "RESULT ok" : $"RESULT failed({_failures.Count})");
        File.WriteAllText(path, string.Join(Environment.NewLine, _lines) + Environment.NewLine);
    }
}
