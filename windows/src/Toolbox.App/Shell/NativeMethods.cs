using System.Runtime.InteropServices;

namespace Toolbox.App.Shell;

/// <summary>
/// 全部 Win32 声明集中在这里。手写而不是用 CsWin32，是为了让"用了哪些系统能力"一眼可数，
/// 也避免为了一个托盘图标引入源生成器。
/// </summary>
internal static class NativeMethods
{
    public const int WsPopup = unchecked((int)0x80000000);
    public const int WsExToolWindow = 0x00000080;

    public const int WmHotkey = 0x0312;
    public const int WmNull = 0x0000;
    public const int WmContextMenu = 0x007B;
    public const int WmLButtonUp = 0x0202;
    public const int WmRButtonUp = 0x0205;

    /// <summary>托盘回调消息：WM_APP + 1，避开系统消息区。</summary>
    public const int TrayCallbackMessage = 0x0400 + 1;

    public const int SmCxSmIcon = 49;

    public const uint ImageIcon = 1;
    public const uint LrLoadFromFile = 0x00000010;

    // NOTIFYICONDATA 的 uFlags
    public const uint NifMessage = 0x01;
    public const uint NifIcon = 0x02;
    public const uint NifTip = 0x04;
    public const uint NifInfo = 0x10;

    // Shell_NotifyIcon 的 dwMessage
    public const uint NimAdd = 0;
    public const uint NimModify = 1;
    public const uint NimDelete = 2;
    public const uint NimSetVersion = 4;

    /// <summary>NOTIFYICON_VERSION_4：回调参数改成"通知码 + 图标 id"，坐标另取。</summary>
    public const uint NotifyIconVersion4 = 4;

    public const uint NiifInfo = 0x1;
    public const uint NiifError = 0x3;

    /// <summary>v4 语义下的通知码（lParam 低字）。</summary>
    public const int NinSelect = 0x0400;
    public const int NinKeySelect = 0x0401;

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NotifyIconData
    {
        public int Size;
        public IntPtr Window;
        public int Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;

        public uint State;
        public uint StateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;

        public uint Version;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;

        public uint InfoFlags;
        public Guid Item;
        public IntPtr BalloonIcon;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RegisterWindowMessage(string message);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint load);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr icon);
}
