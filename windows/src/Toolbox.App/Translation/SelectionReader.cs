using System.Runtime.InteropServices;
using System.Windows.Automation;
using Toolbox.App.Clipboard;
using Toolbox.App.Shell;

namespace Toolbox.App.Translation;

/// <summary>
/// 取当前选中的文本。UIA TextPattern 优先（不动剪贴板、不惊动目标应用），
/// 失败再走「发 Ctrl+C → 读剪贴板 → 恢复原剪贴板」。
///
/// Ctrl+C 产生的内容会经过剪贴板，前后都要打自写标记 —— 否则用户划的词会被自己的
/// 采集记进历史，历史里出现一条用户没复制过的内容。
/// </summary>
internal static class SelectionReader
{
    private const int MaxCharacters = 5000;

    /// <summary>返回 null 表示没有选中文本。</summary>
    public static string? Read(Action markSelfWrite)
    {
        var viaUia = ReadViaUIA();
        if (!string.IsNullOrWhiteSpace(viaUia)) return viaUia!.Trim();

        return ReadViaCopy(markSelfWrite);
    }

    private static string? ReadViaUIA()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element?.GetCurrentPattern(TextPattern.Pattern) is not TextPattern pattern) return null;

            var selections = pattern.GetSelection();
            if (selections.Length == 0) return null;

            var text = selections[0].GetText(MaxCharacters);
            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch
        {
            // 终端、游戏、自绘控件大多不支持 TextPattern，静默走回退
            return null;
        }
    }

    private static string? ReadViaCopy(Action markSelfWrite)
    {
        var previous = TryGetClipboardText();
        markSelfWrite();

        if (!ClipboardPaste.SendCombo(NativeMethods.VkControl, NativeMethods.VkC).Ok)
        {
            markSelfWrite();   // 后面的恢复动作也可能动剪贴板，标记要续期
            return null;
        }

        // 目标应用要处理 Ctrl+C 并把内容放进剪贴板；读的时候也要容忍剪贴板被占
        Thread.Sleep(120);
        var text = TryGetClipboardText();

        if (!string.IsNullOrEmpty(previous)) ClipboardPaste.WriteText(previous);
        markSelfWrite();

        return string.IsNullOrWhiteSpace(text) || text == previous ? null : text!.Trim();
    }

    private static string? TryGetClipboardText()
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                return System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null;
            }
            catch (Exception error) when (error is COMException or ExternalException)
            {
                Thread.Sleep(30);
            }
        }
        return null;
    }
}
