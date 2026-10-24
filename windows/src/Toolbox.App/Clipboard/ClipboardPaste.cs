using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Toolbox.App.Shell;
using Toolbox.Core.Clipboard;

namespace Toolbox.App.Clipboard;

internal enum PasteOutcome
{
    Pasted,
    /// <summary>内容已进剪贴板，但没自动粘贴。降级不是失败：用户自己按一次 Ctrl+V 就行。</summary>
    CopiedOnly,
    Failed,
}

/// <summary>
/// 把一条历史内容写回剪贴板，并尝试粘贴回原来的窗口（与 Mac 版的 PasteSimulator 同职责）。
///
/// 步骤顺序是契约的一部分，改动要连带想清楚后果：
/// 1. 先校验内容，空内容不许清掉用户当前的剪贴板；
/// 2. 写剪贴板 + 打自写标记（**必须在切前台之前**，反了会把旧内容粘出去）；
/// 3. 关掉自己的面板；
/// 4. 切前台，**确认真的切过去了**再发 Ctrl+V。
/// </summary>
internal static class ClipboardPaste
{
    /// <summary>返回结果与给用户看的说明。</summary>
    public static (PasteOutcome Outcome, string Message) Paste(
        ClipboardStore store, ClipboardItem item, ClipboardMonitor monitor, IntPtr targetWindow)
    {
        var png = item.Kind == ClipboardKind.Image && item.MediaSha256 is { } sha ? store.LoadImage(sha) : null;

        if (!HasPayload(item, png)) return (PasteOutcome.Failed, "这条内容读不出来了，可能已被清理");

        if (!WriteToClipboard(item, png)) return (PasteOutcome.Failed, "剪贴板被其它程序占用，写入失败");
        monitor.MarkSelfWrite();

        if (targetWindow == IntPtr.Zero) return (PasteOutcome.CopiedOnly, "已复制到剪贴板（没有可粘贴的目标窗口）");

        NativeMethods.SetForegroundWindow(targetWindow);
        if (!WaitForForeground(targetWindow))
        {
            // 目标窗口可能是管理员进程：UIPI 会拦掉我们合成的按键。
            // 这时候硬发 Ctrl+V 会打到别的窗口上，只能停在"已复制"。
            return (PasteOutcome.CopiedOnly, "已复制到剪贴板。目标窗口没切过来，请手动按 Ctrl+V");
        }

        return SendCtrlV()
            ? (PasteOutcome.Pasted, "")
            : (PasteOutcome.CopiedOnly, "已复制到剪贴板，但合成按键失败，请手动按 Ctrl+V");
    }

    private static bool HasPayload(ClipboardItem item, byte[]? png) => item.Kind switch
    {
        ClipboardKind.Text => !string.IsNullOrEmpty(item.Text),
        ClipboardKind.FileUrls => item.FilePaths is { Count: > 0 },
        ClipboardKind.Image => png is { Length: > 0 },
        _ => false,
    };

    /// <summary>剪贴板经常被别的程序占着，重试几次比直接判失败好。</summary>
    private static bool WriteToClipboard(ClipboardItem item, byte[]? png)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                switch (item.Kind)
                {
                    case ClipboardKind.Text:
                        System.Windows.Clipboard.SetText(item.Text ?? "");
                        break;

                    case ClipboardKind.FileUrls:
                        var paths = new StringCollection();
                        foreach (var path in item.FilePaths ?? []) paths.Add(path);
                        System.Windows.Clipboard.SetFileDropList(paths);
                        break;

                    case ClipboardKind.Image:
                        using (var stream = new MemoryStream(png!))
                        {
                            var frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                            System.Windows.Clipboard.SetImage(frame);
                        }
                        break;

                    default:
                        return false;
                }

                return true;
            }
            catch (COMException) when (attempt < 4)
            {
                Thread.Sleep(30);
            }
            catch (ExternalException) when (attempt < 4)
            {
                Thread.Sleep(30);
            }
        }

        return false;
    }

    /// <summary>
    /// 切前台是异步的（目标进程要响应），必须等它真成为前台再发键，
    /// 否则 Ctrl+V 会打进当时还在前台的那个窗口。
    /// </summary>
    private static bool WaitForForeground(IntPtr target)
    {
        for (var attempt = 0; attempt < 30; attempt++)
        {
            if (NativeMethods.GetForegroundWindow() == target) return true;
            Thread.Sleep(10);
        }
        return false;
    }

    private static bool SendCtrlV()
    {
        var inputs = new NativeMethods.Input[]
        {
            Key(NativeMethods.VkControl, up: false),
            Key(NativeMethods.VkV, up: false),
            Key(NativeMethods.VkV, up: true),
            Key(NativeMethods.VkControl, up: true),
        };

        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        return sent == inputs.Length;
    }

    private static NativeMethods.Input Key(ushort virtualKey, bool up) => new()
    {
        Type = NativeMethods.InputKeyboard,
        Data = new NativeMethods.InputUnion
        {
            Keyboard = new NativeMethods.KeyboardInput
            {
                VirtualKey = virtualKey,
                Flags = up ? NativeMethods.KeyeventfKeyUp : 0,
            },
        },
    };
}
