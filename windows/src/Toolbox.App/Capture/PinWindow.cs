using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Toolbox.App.Shell;

namespace Toolbox.App.Capture;

/// <summary>
/// 贴图窗（对齐 macOS PinWindow 的能力集）：
/// 拖动移动 · 滚轮缩放 · Ctrl+滚轮透明度 · R 旋转 · X 鼠标穿透 ·
/// Ctrl+0 原始大小 · Ctrl+C 复制 · Ctrl+S 保存 · T 置顶切换 · 双击/右键关闭。
/// 穿透后窗口收不到任何事件，只能靠 F3（全局热键）收回 —— 所以 KillAllPins 必须常驻。
/// </summary>
internal sealed class PinWindow : Window
{
    private readonly double _baseWidth;
    private readonly double _baseHeight;
    private readonly Image _image;
    private readonly Border _border;
    private readonly PinCallbacks _callbacks;
    private readonly BitmapSource _source;

    private double _zoom = 1;
    private int _angle;
    private bool _passthrough;

    public PinWindow(BitmapSource source, Rect bounds) : this(source, bounds, PinCallbacks.None) { }

    public PinWindow(BitmapSource source, Rect bounds, PinCallbacks callbacks)
    {
        _source = source;
        _callbacks = callbacks;
        _baseWidth = Math.Max(24, bounds.Width);
        _baseHeight = Math.Max(24, bounds.Height);

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = true;
        WindowStartupLocation = WindowStartupLocation.Manual;

        Left = bounds.Left;
        Top = bounds.Top;
        Width = _baseWidth;
        Height = _baseHeight;

        _image = new Image
        {
            Source = source,
            Stretch = Stretch.Fill,     // 贴图要和选区严丝合缝，不是保持比例留白
        };
        _border = new Border
        {
            Child = _image,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)),
            BorderThickness = new Thickness(1),
        };
        Content = _border;

        MouseLeftButtonDown += (_, _) =>
        {
            try { DragMove(); }
            catch { /* 拖动中再点会抛 InvalidOperationException，忽略 */ }
        };
        MouseWheel += OnWheel;
        MouseDoubleClick += (_, _) => Close();
        MouseRightButtonDown += (_, _) => Close();
        PreviewKeyDown += OnKeyDown;
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.R:
                Rotate();
                e.Handled = true;
                break;
            case Key.X:
                TogglePassthrough();
                e.Handled = true;
                break;
            case Key.T:
                Topmost = !Topmost;
                e.Handled = true;
                break;
            case Key.D0 when Keyboard.Modifiers == ModifierKeys.Control:
                ResetSize();
                e.Handled = true;
                break;
            case Key.C when Keyboard.Modifiers == ModifierKeys.Control:
                _callbacks.CopyToClipboard?.Invoke(_source);
                e.Handled = true;
                break;
            case Key.S when Keyboard.Modifiers == ModifierKeys.Control:
                _callbacks.SaveToFile?.Invoke(_source);
                e.Handled = true;
                break;
        }
    }

    private void OnWheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control)
        {
            Opacity = Math.Clamp(Opacity + (e.Delta > 0 ? 0.05 : -0.05), 0.15, 1.0);
            e.Handled = true;
            return;
        }

        _zoom = Math.Clamp(_zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1), 0.2, 8);
        // 以左上角为锚缩放：贴图本来就该贴在原位置，锚点跟着鼠标走反而难用
        ApplySize();
        e.Handled = true;
    }

    private void Rotate()
    {
        _angle = (_angle + 90) % 360;
        _image.LayoutTransform = new RotateTransform(_angle);
        ApplySize();
    }

    private void ResetSize()
    {
        _zoom = 1;
        _angle = 0;
        _image.LayoutTransform = Transform.Identity;
        ApplySize();
    }

    private void ApplySize()
    {
        // 旋转 90°/270° 后内容宽高互换，窗口也要跟着换，否则图会被拉伸变形
        var swapped = _angle is 90 or 270;
        Width = (swapped ? _baseHeight : _baseWidth) * _zoom;
        Height = (swapped ? _baseWidth : _baseHeight) * _zoom;
    }

    /// <summary>
    /// 鼠标穿透：WS_EX_TRANSPARENT 让所有输入直接落到下面的窗口。
    /// 一旦开了，窗口自己再也收不到事件 —— 关闭/恢复只能靠 F3。
    /// </summary>
    public void TogglePassthrough()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;

        _passthrough = !_passthrough;
        var style = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GwlExStyle);
        style = _passthrough
            ? style | NativeMethods.WsExTransparent | NativeMethods.WsExLayered
            : style & ~(NativeMethods.WsExTransparent);
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GwlExStyle, style);

        // 穿透后视觉上要有区分，否则用户不知道自己点不中它
        _border.BorderBrush = _passthrough
            ? new SolidColorBrush(Color.FromArgb(0x99, 0xE5, 0x39, 0x35))
            : new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0));
    }

    /// <summary>把贴图内容保存为 PNG（PinCallbacks.SaveToFile 的默认实现助手）。</summary>
    public static void SavePngDialog(BitmapSource source, Action<string> report)
    {
        var dialog = new SaveFileDialog
        {
            Filter = "PNG 图片|*.png",
            FileName = $"贴图-{DateTime.Now:yyyyMMdd-HHmmss}.png",
        };
        if (dialog.ShowDialog() != true) return;

        try
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source));
            using var stream = File.Create(dialog.FileName);
            encoder.Save(stream);
            report($"贴图已保存：{dialog.FileName}");
        }
        catch (Exception error)
        {
            report($"保存失败：{error.Message}");
        }
    }
}
