using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace Toolbox.App.Capture;

/// <summary>
/// 截图遮罩窗：盖住光标所在显示器，半透明压暗，划出选区后选区内"亮起来"
/// （用裁剪过的原图盖在暗层上实现），选区旁出尺寸提示和工具栏。
/// Esc 取消；双击选区 = 复制。
/// </summary>
internal sealed class CaptureOverlay : Window
{
    private readonly ScreenCapture _capture;
    private readonly Action<BitmapSource> _onCopy;
    private readonly Action<BitmapSource, Rect> _onPin;
    private readonly Action<string> _report;

    private readonly Rectangle _dark;
    private readonly Image _frozen;
    private readonly Rectangle _selectionRect;
    private readonly TextBlock _sizeHint;
    private readonly StackPanel _toolbar;

    private Point _start;
    private Rect _selection;
    private bool _dragging;
    private bool _selected;

    public CaptureOverlay(ScreenCapture capture, Action<BitmapSource> onCopy,
                          Action<BitmapSource, Rect> onPin, Action<string> report)
    {
        _capture = capture;
        _onCopy = onCopy;
        _onPin = onPin;
        _report = report;

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = true;
        Cursor = Cursors.Cross;
        WindowStartupLocation = WindowStartupLocation.Manual;

        var scale = _capture.DpiScale;
        Left = _capture.MonitorPixels.Left / scale;
        Top = _capture.MonitorPixels.Top / scale;
        Width = _capture.PixelWidth / scale;
        Height = _capture.PixelHeight / scale;

        _dark = new Rectangle { Fill = new SolidColorBrush(Color.FromArgb(0x60, 0, 0, 0)) };
        _frozen = new Image
        {
            Source = _capture.Image,
            Stretch = Stretch.Fill,
            Visibility = Visibility.Hidden,
        };
        _selectionRect = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5)),
            StrokeThickness = 1,
            Visibility = Visibility.Collapsed,
        };
        _sizeHint = new TextBlock
        {
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0xC0, 0x30, 0x30, 0x30)),
            Padding = new Thickness(6, 2, 6, 2),
            FontSize = 12,
            Visibility = Visibility.Collapsed,
        };
        _toolbar = BuildToolbar();

        var canvas = new Canvas();
        foreach (var element in new UIElement[] { _dark, _frozen, _selectionRect, _sizeHint, _toolbar })
            canvas.Children.Add(element);
        Content = canvas;

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
        };
        MouseLeftButtonDown += OnMouseDown;
        MouseMove += OnMouseMove;
        MouseLeftButtonUp += OnMouseUp;
        MouseDoubleClick += (_, _) =>
        {
            if (_selected) CopySelection();
        };
    }

    private StackPanel BuildToolbar()
    {
        Button button(string label, RoutedEventHandler onClick) =>
            new() { Content = label, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(2, 0, 2, 0) };
        var copy = button("复制", (_, _) => CopySelection());
        var pin = button("贴图", (_, _) => PinSelection());
        var save = button("保存", (_, _) => SaveSelection());
        var cancel = button("取消", (_, _) => Close());
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Background = Brushes.White,
            Visibility = Visibility.Collapsed,
        };
        foreach (var b in new[] { copy, pin, save, cancel }) panel.Children.Add(b);
        return panel;
    }

    // ---- 划选 ----

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_selected) return;   // 选区已定，鼠标交给工具栏
        _start = e.GetPosition(this);
        _dragging = true;
        _selectionRect.Visibility = Visibility.Visible;
        _frozen.Visibility = Visibility.Visible;
        _toolbar.Visibility = Visibility.Collapsed;
        UpdateSelection(_start);
        CaptureMouse();
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragging) return;
        UpdateSelection(e.GetPosition(this));
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();

        // 小于 3x3 像素视为误触（与 Core 的 CaptureGeometry 同一约定）
        if (_selection.Width * _capture.DpiScale < 3 || _selection.Height * _capture.DpiScale < 3)
        {
            _selectionRect.Visibility = Visibility.Collapsed;
            _frozen.Visibility = Visibility.Hidden;
            _sizeHint.Visibility = Visibility.Collapsed;
            return;
        }

        _selected = true;
        ShowToolbar();
    }

    private void UpdateSelection(Point current)
    {
        var left = Math.Min(_start.X, current.X);
        var top = Math.Min(_start.Y, current.Y);
        var width = Math.Abs(current.X - _start.X);
        var height = Math.Abs(current.Y - _start.Y);

        _selection = new Rect(left, top, width, height);
        Canvas.SetLeft(_selectionRect, left);
        Canvas.SetTop(_selectionRect, top);
        _selectionRect.Width = width;
        _selectionRect.Height = height;

        // 选区内"亮起来"：把冻结原图裁到选区，盖在暗层上面
        _frozen.Clip = new RectangleGeometry(_selection);

        Canvas.SetLeft(_sizeHint, left);
        Canvas.SetTop(_sizeHint, top + height + 6);
        _sizeHint.Text = $"{(int)(width * _capture.DpiScale)} × {(int)(height * _capture.DpiScale)}";
        _sizeHint.Visibility = Visibility.Visible;
    }

    private void ShowToolbar()
    {
        _toolbar.Visibility = Visibility.Visible;
        var below = _selection.Y + _selection.Height + 8;
        var fits = below + 36 < ActualHeight;
        Canvas.SetLeft(_toolbar, Math.Clamp(_selection.X, 4, ActualWidth - _toolbar.ActualWidth - 4));
        Canvas.SetTop(_toolbar, fits ? below : Math.Max(4, _selection.Y - 44));
    }

    // ---- 动作 ----

    private BitmapSource? CropSelection()
    {
        if (!_selected) return null;
        var scale = _capture.DpiScale;
        return new CroppedBitmap(_capture.Image, new Int32Rect(
            (int)(_selection.X * scale),
            (int)(_selection.Y * scale),
            Math.Max(1, (int)(_selection.Width * scale)),
            Math.Max(1, (int)(_selection.Height * scale))));
    }

    private Rect SelectionScreenRect() =>
        new(Left + _selection.X, Top + _selection.Y, _selection.Width, _selection.Height);

    private void CopySelection()
    {
        var cropped = CropSelection();
        if (cropped is null) return;
        try
        {
            // 截图复制是真实复制，应该进历史，不打自写标记
            System.Windows.Clipboard.SetImage(cropped);
            _onCopy(cropped);
            Close();
        }
        catch (Exception error)
        {
            _report($"复制截图失败：{error.Message}");
        }
    }

    private void PinSelection()
    {
        var cropped = CropSelection();
        if (cropped is null) return;
        _onPin(cropped, SelectionScreenRect());
        Close();
    }

    private void SaveSelection()
    {
        var cropped = CropSelection();
        if (cropped is null) return;

        var dialog = new SaveFileDialog
        {
            Filter = "PNG 图片|*.png",
            FileName = $"Toolbox-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            using var stream = new FileStream(dialog.FileName, FileMode.Create);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(cropped));
            encoder.Save(stream);
            _report($"截图已保存：{dialog.FileName}");
            Close();
        }
        catch (Exception error)
        {
            _report($"保存失败：{error.Message}");
        }
    }
}
