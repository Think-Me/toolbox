using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace Toolbox.App.Capture;

internal enum CaptureTool
{
    None,
    Rectangle,
    Ellipse,
    Arrow,
    Pen,
    Text,
    Mosaic,
}

/// <summary>标注的纯数据。坐标全部是**选区内 DIP**，导出时按 DPI 换算成像素。</summary>
internal abstract record Annotation;
internal sealed record RectNote(Rect R) : Annotation;
internal sealed record EllipseNote(Rect R) : Annotation;
internal sealed record ArrowNote(Point From, Point To) : Annotation;
internal sealed record PenNote(IReadOnlyList<Point> Points) : Annotation;
internal sealed record MosaicNote(Rect R) : Annotation;
internal sealed record TextNote(Point Position, string Text) : Annotation;

/// <summary>
/// 截图遮罩窗：盖住光标所在显示器，压暗，划出选区后选区内"亮起来"，
/// 选区上可用标注工具（矩形/箭头/画笔/马赛克/撤销），工具栏出复制/贴图/保存/取消。
/// Esc 取消；双击选区 = 复制（仅在没有激活标注工具时）。
///
/// 标注立即栅格化进 WriteableBitmap：导出所见即所得，撤销 = 重画整个列表。
/// </summary>
internal sealed class CaptureOverlay : Window
{
    private static readonly Color NoteColor = Color.FromRgb(0xE5, 0x39, 0x35);
    private const double NoteThickness = 3;

    private readonly ScreenCapture _capture;
    private readonly Action<BitmapSource> _onCopy;
    private readonly Action<BitmapSource, Rect> _onPin;
    private readonly Action<string> _report;

    private readonly Rectangle _dark;
    private readonly Image _frozen;
    private readonly Image _regionImage;
    private readonly Rectangle _selectionRect;
    private readonly TextBlock _sizeHint;
    private readonly Canvas _previewCanvas;
    private readonly StackPanel _toolPanel;
    private readonly StackPanel _actionPanel;
    private readonly Dictionary<CaptureTool, Button> _toolButtons = new();

    private Point _start;
    private Rect _selection;
    private bool _dragging;
    private bool _selected;
    private CaptureTool _activeTool = CaptureTool.Rectangle;

    private CroppedBitmap? _baseCropped;
    private WriteableBitmap? _canvasBitmap;
    private readonly List<Annotation> _annotations = [];
    private List<Point> _penPoints = [];

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
        _regionImage = new Image
        {
            Stretch = Stretch.Fill,
            Visibility = Visibility.Collapsed,
        };
        _selectionRect = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5)),
            StrokeThickness = 1,
            Visibility = Visibility.Collapsed,
        };
        _previewCanvas = new Canvas
        {
            IsHitTestVisible = false,
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
        _toolPanel = BuildToolPanel();
        _actionPanel = BuildActionPanel();

        var canvas = new Canvas();
        foreach (var element in new UIElement[]
                 {
                     _dark, _frozen, _regionImage, _selectionRect, _previewCanvas, _sizeHint,
                     _toolPanel, _actionPanel,
                 })
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
    }

    // ---- 工具栏 ----

    private StackPanel BuildToolPanel()
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Background = Brushes.White,
            Visibility = Visibility.Collapsed,
        };

        void AddTool(CaptureTool tool, string label)
        {
            var button = new Button { Content = label, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(2, 2, 2, 2) };
            button.Click += (_, _) => SelectTool(tool);
            _toolButtons[tool] = button;
            panel.Children.Add(button);
        }

        AddTool(CaptureTool.Rectangle, "矩形");
        AddTool(CaptureTool.Ellipse, "椭圆");
        AddTool(CaptureTool.Arrow, "箭头");
        AddTool(CaptureTool.Pen, "画笔");
        AddTool(CaptureTool.Text, "文字");
        AddTool(CaptureTool.Mosaic, "马赛克");

        var undo = new Button { Content = "撤销", Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(8, 2, 2, 2) };
        undo.Click += (_, _) => Undo();
        panel.Children.Add(undo);
        return panel;
    }

    private StackPanel BuildActionPanel()
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Background = Brushes.White,
            Visibility = Visibility.Collapsed,
        };

        Button button(string label, RoutedEventHandler onClick) =>
            new() { Content = label, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(2, 2, 2, 2) };

        panel.Children.Add(button("复制", (_, _) => CopySelection()));
        panel.Children.Add(button("贴图", (_, _) => PinSelection()));
        panel.Children.Add(button("保存", (_, _) => SaveSelection()));
        panel.Children.Add(button("取消", (_, _) => Close()));
        return panel;
    }

    private void SelectTool(CaptureTool tool)
    {
        _activeTool = _activeTool == tool ? CaptureTool.None : tool;
        SyncToolbar();
    }

    private void SyncToolbar()
    {
        var active = new SolidColorBrush(Color.FromRgb(0xBB, 0xDE, 0xFB));
        var idle = Brushes.White;
        foreach (var (tool, button) in _toolButtons)
            button.Background = tool == _activeTool ? active : idle;
    }

    // ---- 划选 ----

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        var point = e.GetPosition(this);

        if (!_selected)
        {
            _start = point;
            _dragging = true;
            _selectionRect.Visibility = Visibility.Visible;
            _frozen.Visibility = Visibility.Visible;
            _toolPanel.Visibility = Visibility.Collapsed;
            _actionPanel.Visibility = Visibility.Collapsed;
            UpdateSelection(point);
            CaptureMouse();
            return;
        }

        if (_activeTool == CaptureTool.None || !_selection.Contains(point)) return;

        _start = ClampToSelection(point);
        _dragging = true;
        CaptureMouse();

        switch (_activeTool)
        {
            case CaptureTool.Pen:
                _penPoints = [_start];
                break;
            case CaptureTool.Rectangle:
                BeginPreview(new Rectangle
                {
                    Stroke = NoteBrush,
                    StrokeThickness = NoteThickness,
                }, _start);
                break;
            case CaptureTool.Ellipse:
                BeginPreview(new Ellipse
                {
                    Stroke = NoteBrush,
                    StrokeThickness = NoteThickness,
                }, _start);
                break;
            case CaptureTool.Arrow:
                BeginPreview(new Line
                {
                    Stroke = NoteBrush,
                    StrokeThickness = NoteThickness,
                    X1 = _start.X, Y1 = _start.Y, X2 = _start.X, Y2 = _start.Y,
                }, _start);
                break;
            case CaptureTool.Mosaic:
                BeginPreview(new Rectangle
                {
                    Fill = new SolidColorBrush(Color.FromArgb(0x60, 0x90, 0x90, 0x90)),
                    Stroke = NoteBrush,
                    StrokeThickness = 1,
                }, _start);
                break;
            case CaptureTool.Text:
                // 文字不需要拖拽：落点弹输入框，回车提交
                _dragging = false;
                ShowTextBox(_start);
                break;
        }
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        var point = e.GetPosition(this);
        if (!_dragging)
        {
            return;
        }

        if (!_selected)
        {
            UpdateSelection(point);
            return;
        }

        var clamped = ClampToSelection(point);
        switch (_activeTool)
        {
            case CaptureTool.Rectangle or CaptureTool.Mosaic:
                UpdatePreviewRect(_start, clamped);
                break;
            case CaptureTool.Arrow:
                UpdatePreviewArrow(_start, clamped);
                break;
            case CaptureTool.Pen:
                _penPoints.Add(clamped);
                UpdatePreviewPen();
                break;
        }
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();

        if (!_selected)
        {
            // 小于 3x3 像素视为误触（与 Core 的 CaptureGeometry 同一约定）
            if (_selection.Width * _capture.DpiScale < 3 || _selection.Height * _capture.DpiScale < 3)
            {
                _selectionRect.Visibility = Visibility.Collapsed;
                _frozen.Visibility = Visibility.Hidden;
                _sizeHint.Visibility = Visibility.Collapsed;
                return;
            }

            _selected = true;
            FinishSelection();
            return;
        }

        var end = ClampToSelection(e.GetPosition(this));
        switch (_activeTool)
        {
            case CaptureTool.Rectangle:
                CommitPreview(new RectNote(RectFrom(_start, end)));
                break;
            case CaptureTool.Ellipse:
                CommitPreview(new EllipseNote(RectFrom(_start, end)));
                break;
            case CaptureTool.Mosaic:
                CommitPreview(new MosaicNote(RectFrom(_start, end)));
                break;
            case CaptureTool.Arrow:
                CommitPreview(new ArrowNote(_start, end));
                break;
            case CaptureTool.Pen:
                if (_penPoints.Count >= 2) CommitPreview(new PenNote(_penPoints));
                else ClearPreview();
                _penPoints = [];
                break;
        }
    }

    /// <summary>文字标注：落点放一个输入框，Enter 提交、Esc 或空文本取消。</summary>
    private void ShowTextBox(Point position)
    {
        ClearPreview();
        _previewCanvas.Visibility = Visibility.Visible;

        var box = new TextBox
        {
            MinWidth = 120,
            Background = Brushes.White,
            BorderBrush = NoteBrush,
            BorderThickness = new Thickness(1),
            FontSize = 14,
        };
        Canvas.SetLeft(box, position.X);
        Canvas.SetTop(box, position.Y);
        _previewCanvas.Children.Add(box);
        box.Focus();

        void Commit()
        {
            var text = box.Text.Trim();
            _previewCanvas.Children.Remove(box);
            if (_previewCanvas.Children.Count == 0) _previewCanvas.Visibility = Visibility.Collapsed;
            if (text.Length > 0)
            {
                _annotations.Add(new TextNote(position, text));
                RenderAnnotations();
            }
        }

        box.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Key.Enter:
                    Commit();
                    e.Handled = true;
                    break;
                case Key.Escape:
                    _previewCanvas.Children.Remove(box);
                    if (_previewCanvas.Children.Count == 0) _previewCanvas.Visibility = Visibility.Collapsed;
                    e.Handled = true;
                    break;
            }
        };
        box.LostKeyboardFocus += (_, _) =>
        {
            if (_previewCanvas.Children.Contains(box)) Commit();
        };
    }

    // ---- 选区 ----

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

        // 选区内"亮起来"：把冻结原图裁到选区，盖在暗层上面（标注阶段换成画布位图）
        _frozen.Clip = new RectangleGeometry(_selection);

        Canvas.SetLeft(_sizeHint, left);
        Canvas.SetTop(_sizeHint, top + height + 6);
        _sizeHint.Text = $"{(int)(width * _capture.DpiScale)} × {(int)(height * _capture.DpiScale)}";
        _sizeHint.Visibility = Visibility.Visible;
    }

    /// <summary>选区确定：裁出底图，建画布位图，显示工具栏并默认选中矩形工具。</summary>
    private void FinishSelection()
    {
        var scale = _capture.DpiScale;
        var x = (int)(_selection.X * scale);
        var y = (int)(_selection.Y * scale);
        var width = Math.Max(1, (int)(_selection.Width * scale));
        var height = Math.Max(1, (int)(_selection.Height * scale));

        _baseCropped = new CroppedBitmap(_capture.Image, new Int32Rect(x, y, width, height));
        _canvasBitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
        RenderAnnotations();

        // 亮区从"裁剪的原图"切换成"可标注的画布"
        _frozen.Visibility = Visibility.Hidden;
        _regionImage.Source = _canvasBitmap;
        Canvas.SetLeft(_regionImage, _selection.X);
        Canvas.SetTop(_regionImage, _selection.Y);
        _regionImage.Width = _selection.Width;
        _regionImage.Height = _selection.Height;
        _regionImage.Visibility = Visibility.Visible;

        _toolPanel.Visibility = Visibility.Visible;
        _actionPanel.Visibility = Visibility.Visible;
        SelectTool(CaptureTool.Rectangle);
        ShowPanels();
    }

    private void ShowPanels()
    {
        var scale = _capture.DpiScale;
        var left = Math.Clamp(_selection.X + _selection.Width - 300, 4, ActualWidth - 304);
        var bottom = _selection.Y + _selection.Height + 8;
        var panelHeight = _toolPanel.ActualHeight + _actionPanel.ActualHeight + 12;
        var fits = bottom + panelHeight < ActualHeight;
        var top = fits ? bottom : Math.Max(4, _selection.Y - panelHeight - 8);

        Canvas.SetLeft(_toolPanel, left);
        Canvas.SetTop(_toolPanel, top);
        Canvas.SetLeft(_actionPanel, left);
        Canvas.SetTop(_actionPanel, top + _toolPanel.ActualHeight + 6);
    }

    private void RenderAnnotations()
    {
        if (_baseCropped is null || _canvasBitmap is null) return;

        var width = _canvasBitmap.PixelWidth;
        var height = _canvasBitmap.PixelHeight;
        var scale = width / _selection.Width;

        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawImage(_baseCropped, new Rect(0, 0, width, height));
            foreach (var annotation in _annotations)
                DrawAnnotation(dc, annotation, scale);
        }

        var rtb = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);

        var stride = width * 4;
        var buffer = new byte[stride * height];
        rtb.CopyPixels(buffer, stride, 0);
        _canvasBitmap.WritePixels(new Int32Rect(0, 0, width, height), buffer, stride, 0);
    }

    private void DrawAnnotation(DrawingContext dc, Annotation annotation, double scale)
    {
        var pen = new Pen(new SolidColorBrush(NoteColor), NoteThickness * scale);
        switch (annotation)
        {
            case RectNote rect:
                dc.DrawRectangle(null, pen, Scale(rect.R, scale));
                break;

            case EllipseNote ellipse:
            {
                var r = Scale(ellipse.R, scale);
                // DrawEllipse 要的是左上角 + 半径，WPF Rect 的坐标语义在这里要手动换
                dc.DrawEllipse(null, pen,
                    new Point(r.X + r.Width / 2, r.Y + r.Height / 2),
                    r.Width / 2, r.Height / 2);
                break;
            }

            case TextNote text:
            {
                var formatted = new FormattedText(
                    text.Text,
                    System.Globalization.CultureInfo.CurrentCulture,
                    FlowDirection.LeftToRight,
                    new Typeface(new FontFamily("Microsoft YaHei"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                    14 * scale,
                    new SolidColorBrush(NoteColor),
                    scale);
                dc.DrawText(formatted, Times(text.Position, scale));
                break;
            }

            case ArrowNote arrow:
            {
                var from = Times(arrow.From, scale);
                var to = Times(arrow.To, scale);
                dc.DrawLine(pen, from, to);

                // 箭头头部：两根短线，夹角 25°
                var angle = Math.Atan2(to.Y - from.Y, to.X - from.X);
                var head = Math.Max(10, pen.Thickness * 4);
                dc.DrawLine(pen, to, new Point(
                    to.X - head * Math.Cos(angle - 0.44), to.Y - head * Math.Sin(angle - 0.44)));
                dc.DrawLine(pen, to, new Point(
                    to.X - head * Math.Cos(angle + 0.44), to.Y - head * Math.Sin(angle + 0.44)));
                break;
            }

            case PenNote strokes:
            {
                var geometry = new StreamGeometry();
                using (var ctx = geometry.Open())
                {
                    ctx.BeginFigure(Times(strokes.Points[0], scale), false, false);
                    foreach (var point in strokes.Points.Skip(1)) ctx.LineTo(Times(point, scale), true, false);
                }
                dc.DrawGeometry(null, pen, geometry);
                break;
            }

            case MosaicNote mosaic:
            {
                var mosaicSource = EnsureMosaic();
                if (mosaicSource is null) break;
                var rectPx = ToPixels(mosaic.R, scale);
                var region = new CroppedBitmap(mosaicSource, rectPx);
                dc.DrawImage(region, Scale(mosaic.R, scale));
                break;
            }
        }
    }

    private BitmapSource? _mosaicedSource;

    /// <summary>整块选区的马赛克版本，第一次用马赛克标注时算一次（内容不会再变）。</summary>
    private BitmapSource? EnsureMosaic()
    {
        if (_mosaicedSource is not null) return _mosaicedSource;
        if (_baseCropped is null) return null;

        var width = _baseCropped.PixelWidth;
        var height = _baseCropped.PixelHeight;
        var stride = width * 4;
        var pixels = new byte[stride * height];
        _baseCropped.CopyPixels(pixels, stride, 0);

        var blockSize = Math.Max(4, (int)(12 * _capture.DpiScale));
        var mosaiced = Toolbox.Core.Capture.Mosaic.Apply(
            pixels, width, height, 4, 0, 0, width, height, blockSize);

        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, mosaiced, stride);
        bitmap.Freeze();
        _mosaicedSource = bitmap;
        return bitmap;
    }

    // ---- 预览形状 ----

    private void BeginPreview(Shape shape, Point position)
    {
        ClearPreview();
        SetShapeBounds(shape, position, position);
        _previewCanvas.Children.Add(shape);
        _previewCanvas.Visibility = Visibility.Visible;
    }

    private void UpdatePreviewRect(Point from, Point to)
    {
        if (_previewCanvas.Children.Count == 0) return;
        SetShapeBounds((Shape)_previewCanvas.Children[0], from, to);
    }

    private void UpdatePreviewArrow(Point from, Point to)
    {
        if (_previewCanvas.Children[0] is not Line line) return;
        line.X1 = from.X;
        line.Y1 = from.Y;
        line.X2 = to.X;
        line.Y2 = to.Y;
    }

    private void UpdatePreviewPen()
    {
        if (_penPoints.Count == 0) return;
        ClearPreview();
        var polyline = new Polyline
        {
            Stroke = NoteBrush,
            StrokeThickness = NoteThickness,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        foreach (var point in _penPoints) polyline.Points.Add(point);
        _previewCanvas.Children.Add(polyline);
        _previewCanvas.Visibility = Visibility.Visible;
    }

    private void SetShapeBounds(Shape shape, Point from, Point to)
    {
        var left = Math.Min(from.X, to.X);
        var top = Math.Min(from.Y, to.Y);
        Canvas.SetLeft(shape, left);
        Canvas.SetTop(shape, top);
        shape.Width = Math.Abs(to.X - from.X);
        shape.Height = Math.Abs(to.Y - from.Y);
    }

    private void ClearPreview()
    {
        _previewCanvas.Children.Clear();
        _previewCanvas.Visibility = Visibility.Collapsed;
    }

    /// <summary>提交：预览形状移除，标注进列表并栅格化进画布位图。</summary>
    private void CommitPreview(Annotation annotation)
    {
        ClearPreview();
        _annotations.Add(annotation);
        RenderAnnotations();
    }

    private void Undo()
    {
        if (_annotations.Count == 0) return;
        _annotations.RemoveAt(_annotations.Count - 1);
        RenderAnnotations();
    }

    // ---- 导出动作 ----

    private BitmapSource? ExportImage()
    {
        if (!_selected || _canvasBitmap is null) return null;
        return _canvasBitmap;
    }

    private void CopySelection()
    {
        var image = ExportImage();
        if (image is null) return;
        try
        {
            // 截图复制是真实复制，应该进历史，不打自写标记
            System.Windows.Clipboard.SetImage(image);
            _onCopy(image);
            Close();
        }
        catch (Exception error)
        {
            _report($"复制截图失败：{error.Message}");
        }
    }

    private void PinSelection()
    {
        var image = ExportImage();
        if (image is null) return;
        _onPin(image, SelectionScreenRect());
        Close();
    }

    private void SaveSelection()
    {
        var image = ExportImage();
        if (image is null) return;

        var dialog = new SaveFileDialog
        {
            Filter = "PNG 图片|*.png",
            FileName = $"Toolbox-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var stream = File.Create(dialog.FileName);
            encoder.Save(stream);
            _report($"截图已保存：{dialog.FileName}");
            Close();
        }
        catch (Exception error)
        {
            _report($"保存失败：{error.Message}");
        }
    }

    private Rect SelectionScreenRect() =>
        new(Left + _selection.X, Top + _selection.Y, _selection.Width, _selection.Height);

    // ---- 小工具 ----

    private static readonly Brush NoteBrush = new SolidColorBrush(NoteColor);

    private Point ClampToSelection(Point point) => new(
        Math.Clamp(point.X, _selection.Left, _selection.Right),
        Math.Clamp(point.Y, _selection.Top, _selection.Bottom));

    private static Rect RectFrom(Point a, Point b) =>
        new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));

    private static Rect Scale(Rect r, double scale) => new(r.X * scale, r.Y * scale, r.Width * scale, r.Height * scale);

    private static Point Times(Point p, double scale) => new(p.X * scale, p.Y * scale);

    private Int32Rect ToPixels(Rect r, double scale) => new(
        (int)(r.X * scale), (int)(r.Y * scale),
        Math.Max(1, (int)(r.Width * scale)), Math.Max(1, (int)(r.Height * scale)));
}
