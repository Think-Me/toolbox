using Microsoft.Win32;

namespace Toolbox.App.Proxy;

/// <summary>
/// Windows 系统代理开关：HKCU Internet Settings（免管理员）+ 通知 WinINet 刷新。
/// 对齐 macOS SystemProxy 的职责；macOS 用 networksetup，Windows 直接写注册表。
///
/// 关键细节：改完必须 InternetSetOption(SETTINGS_CHANGED + REFRESH)，
/// 否则已开的浏览器不重启感知不到代理变化。
/// </summary>
internal static class SystemProxyWin
{
    private const string InternetSettings = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    private const int InternetOptionSettingsChanged = 39;
    private const int InternetOptionRefresh = 37;

    /// <summary>
    /// ProxyServer 的格式：分协议各指一个端口。socks 走 SOCKS 键，http/https 走 HTTP 键
    /// （HTTP CONNECT 由 xray 远端解析域名，避开本地 DNS 污染）。
    /// </summary>
    public static string ProxyServerValue(int httpPort, int socksPort) =>
        $"http=127.0.0.1:{httpPort};https=127.0.0.1:{httpPort};socks=127.0.0.1:{socksPort}";

    /// <summary>本地与局域网直连，这些流量不该进代理。</summary>
    public static string ProxyOverrideValue() =>
        "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2?.*;172.30.*;172.31.*;192.168.*;<local>";

    /// <summary>开启系统代理。返回错误说明，null = 成功。</summary>
    public static string? Enable(int httpPort, int socksPort)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(InternetSettings, writable: true)
                ?? throw new InvalidOperationException("打不开注册表 Internet Settings");
            key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
            key.SetValue("ProxyServer", ProxyServerValue(httpPort, socksPort), RegistryValueKind.String);
            key.SetValue("ProxyOverride", ProxyOverrideValue(), RegistryValueKind.String);
            NotifySystem();
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    /// <summary>关闭系统代理（只关开关，不动用户原有 ProxyServer 值）。</summary>
    public static string? Disable()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(InternetSettings, writable: true)
                ?? throw new InvalidOperationException("打不开注册表 Internet Settings");
            key.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
            NotifySystem();
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    /// <summary>当前系统代理是否开着（读真实状态，不信任内存里的布尔）。</summary>
    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(InternetSettings);
            return key?.GetValue("ProxyEnable") is 1;
        }
        catch
        {
            return false;
        }
    }

    [System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOption(IntPtr hinternet, int option, IntPtr buffer, int bufferLength);

    private static void NotifySystem()
    {
        _ = InternetSetOption(IntPtr.Zero, InternetOptionSettingsChanged, IntPtr.Zero, 0);
        _ = InternetSetOption(IntPtr.Zero, InternetOptionRefresh, IntPtr.Zero, 0);
    }
}
