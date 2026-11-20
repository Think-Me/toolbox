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

        // 剪贴板里有文本时先写一次性哨兵（每次唯一）：
        // 「Ctrl+C 之后读到的还是哨兵」= 目标真的什么都没复制（没有选区）。
        // 不能用「读到 == 复制前的内容」判定 —— 用户划选的文本完全可能就是上次复制的
        // 那段（BUG-002：那种情况会被误判成没有选区，翻译直接不弹窗）。
        // 剪贴板没有文本（空 / 图片）时不写哨兵：哨兵会覆盖掉用户的图片内容，
        // 且这种情况下读到任何非空文本都不可能是「旧内容」，旧判定本来就是对的。
        var sentinel = string.IsNullOrEmpty(previous)
            ? null
            : $"toolbox-sentinel-{Guid.NewGuid():N}";
        if (sentinel is not null)
        {
            if (!ClipboardPaste.WriteText(sentinel)) return null;
            markSelfWrite();
        }

        if (!ClipboardPaste.SendCombo(NativeMethods.VkControl, NativeMethods.VkC).Ok)
        {
            RestorePrevious(previous);
            markSelfWrite();   // 后面的恢复动作也可能动剪贴板，标记要续期
            return null;
        }

        // 目标应用要处理 Ctrl+C 并把内容放进剪贴板；读的时候也要容忍剪贴板被占
        Thread.Sleep(120);
        var text = TryGetClipboardText();

        RestorePrevious(previous);
        markSelfWrite();

        if (string.IsNullOrWhiteSpace(text)) return null;
        if (sentinel is not null && text == sentinel) return null;
        return text.Trim();
    }

    /// <summary>把复制前的文本写回去。非文本剪贴板（图片等）无法精确还原，保持调用前的行为。</summary>
    private static void RestorePrevious(string? previous)
    {
        if (!string.IsNullOrEmpty(previous)) ClipboardPaste.WriteText(previous);
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
