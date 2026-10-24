using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Toolbox.App.Capture;

/// <summary>
/// 贴图窗：无边框置顶、拖动、滚轮缩放、Ctrl+滚轮调透明度、双击/右键关闭。
/// 多张贴图各自独立窗口，互不影响。
/// </summary>
internal sealed class PinWindow : Window
{
    private readonly double _baseWidth;
    private readonly double _baseHeight;
    private double _zoom = 1;

    public PinWindow(BitmapSource source, Rect bounds)
    {
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

        var image = new Image
        {
            Source = source,
            Stretch = Stretch.Fill,     // 贴图要和选区严丝合缝，不是保持比例留白
        };
        Content = new Border
        {
            Child = image,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)),
            BorderThickness = new Thickness(1),
        };

        MouseLeftButtonDown += (_, _) =>
        {
            try { DragMove(); }
            catch { /* 拖动中再点会抛 InvalidOperationException，忽略 */ }
        };
        MouseWheel += OnWheel;
        MouseDoubleClick += (_, _) => Close();
        MouseRightButtonDown += (_, _) => Close();
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
        Width = _baseWidth * _zoom;
        Height = _baseHeight * _zoom;
        e.Handled = true;
    }
}
