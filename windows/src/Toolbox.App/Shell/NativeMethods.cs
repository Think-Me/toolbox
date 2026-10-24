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

    /// <summary>MOD_NOREPEAT：按住不放时只触发一次，否则长按会刷出一串菜单。</summary>
    public const uint ModNoRepeat = 0x4000;

    /// <summary>RegisterHotKey 说"已被注册"时 GetLastError 的返回值。</summary>
    public const int ErrorHotkeyAlreadyRegistered = 1409;

    // AppendMenu 的 uFlags
    public const uint MfString = 0x00000000;
    public const uint MfGrayed = 0x00000001;
    public const uint MfChecked = 0x00000008;
    public const uint MfPopup = 0x00000010;
    public const uint MfSeparator = 0x00000800;

    // TrackPopupMenuEx 的 uFlags
    public const uint TpmRightButton = 0x0002;
    public const uint TpmReturnCmd = 0x0100;

    // 剪贴板
    public const int WmClipboardUpdate = 0x031D;
    public const uint CfText = 13;
    public const uint CfDib = 8;
    public const uint CfHDrop = 15;
    public const uint GmMemMoveable = 0x0002;

    // SendInput
    public const uint InputKeyboard = 1;
    public const uint KeyeventfKeyUp = 0x0002;
    public const ushort VkControl = 0x11;
    public const ushort VkV = 0x56;

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

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnregisterHotKey(IntPtr window, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr itemId, string? text);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr window, IntPtr parameters);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    // ---- 剪贴板 ----

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AddClipboardFormatListener(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveClipboardFormatListener(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetClipboardData(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint RegisterClipboardFormat(string format);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UIntPtr GlobalSize(IntPtr memory);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint DragQueryFile(IntPtr drop, uint index, char[]? file, uint length);

    // ---- 前台窗口与进程 ----

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    // ---- 合成按键 ----

    [StructLayout(LayoutKind.Sequential)]
    public struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint count, Input[] inputs, int size);
}
