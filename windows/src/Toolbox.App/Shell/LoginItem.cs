using Microsoft.Win32;

namespace Toolbox.App.Shell;

/// <summary>
/// 开机自启：HKCU\Software\Microsoft\Windows\CurrentVersion\Run 下的一个字符串值。
/// 状态**每次都从注册表读**，不缓存 —— 用户可能在任务管理器里、或用别的工具改过。
/// 写失败时调用方不得翻转显示状态，否则界面会显示一个系统里并不存在的事实。
/// </summary>
internal static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Toolbox";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(ValueName) is string { Length: > 0 };
    }

    /// <summary>成功返回 null，失败返回原因。</summary>
    public static string? Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (key is null) return "打不开 Run 注册表项";

            if (enabled)
            {
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return "拿不到当前程序路径";
                key.SetValue(ValueName, $"\"{exe}\"");
            }
            else if (key.GetValue(ValueName) is not null)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }

            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }
}
