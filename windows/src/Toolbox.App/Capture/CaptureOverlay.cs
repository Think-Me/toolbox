using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;
using Toolbox.App.Shell;
using Toolbox.Core.Capture;
using Toolbox.Core.Settings;

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
    private readonly CaptureSettings _settings;

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

    // ---- 标注编辑（选中 / 移动 / 角柄缩放 / 删除） ----
    private enum EditMode
    {
        None,
        Move,
        Resize,
    }

    private EditMode _editMode;
    private int _editIndex = -1;
    private int _resizeCorner = -1;
    private Point _editStartLocal;
    private Rect _editStartBounds;
    private int? _selectedAnnotation;
    private readonly Canvas _editCanvas;
    private readonly Rectangle _editFrame;
    private readonly Rectangle[] _editHandles = new Rectangle[4];

    // ---- 吸附 / 智能选窗 / 放大镜 ----
    private List<SnapRect> _windowRects = [];
    private (double[] Xs, double[] Ys) _snapTargets = ([], []);
    private SnapRect? _clickCandidate;
    private Point _downPoint;
    private readonly Rectangle _hoverHighlight;
    private readonly Rectangle _guideV;
    private readonly Rectangle _guideH;
    private readonly Border _loupe;
    private readonly Image _loupeImage;
    private readonly TextBlock _loupeLabel;

    public CaptureOverlay(ScreenCapture capture, Action<BitmapSource> onCopy,
                          Action<BitmapSource, Rect> onPin, Action<string> report,
                          CaptureSettings settings)
    {
        _capture = capture;
        _onCopy = onCopy;
        _onPin = onPin;
        _report = report;
        _settings = settings;

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
        // 编辑层：选中框 + 角柄。独立于 previewCanvas，因为 ClearPreview 会清空后者
        _editCanvas = new Canvas { IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        _editFrame = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5)),
            StrokeThickness = 1,
            StrokeDashArray = [3, 2],
            Visibility = Visibility.Collapsed,
        };
        for (var i = 0; i < 4; i++)
        {
            _editHandles[i] = new Rectangle
            {
                Width = 8,
                Height = 8,
                Fill = Brushes.White,
                Stroke = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5)),
                StrokeThickness = 1,
                Visibility = Visibility.Collapsed,
            };
            _editCanvas.Children.Add(_editHandles[i]);
        }
        _editCanvas.Children.Add(_editFrame);
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

        // 悬停高亮：鼠标下方的完整窗口（智能选窗目标）
        _hoverHighlight = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromArgb(0xB0, 0x1E, 0x88, 0xE5)),
            StrokeThickness = 2,
            Fill = new SolidColorBrush(Color.FromArgb(0x18, 0x1E, 0x88, 0xE5)),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        // 吸附辅助线：吸上哪条边就在哪画一条竖/横线
        _guideV = MakeGuideLine(vertical: true);
        _guideH = MakeGuideLine(vertical: false);
        (_loupe, _loupeImage, _loupeLabel) = BuildLoupe();

        var canvas = new Canvas();
        foreach (var element in new UIElement[]
                 {
                     _dark, _frozen, _regionImage, _selectionRect, _hoverHighlight,
                     _previewCanvas, _editCanvas, _sizeHint, _guideV, _guideH, _loupe,
                     _toolPanel, _actionPanel,
                 })
            canvas.Children.Add(element);
        Content = canvas;

        // 窗口候选与吸附线：EnumWindows 的返回顺序即 Z 序（从前到后）
        var windowRectsPx = WindowCandidates.VisibleTopLevelRects();
        _windowRects = WindowCandidates.ToOverlayDip(windowRectsPx, _capture.MonitorPixels, scale);
        _snapTargets = SelectionSnapping.Targets(_windowRects, new SnapRect(0, 0, Width, Height));

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
            else if (e.Key is Key.Delete or Key.Back && _selectedAnnotation is { } index)
            {
                _annotations.RemoveAt(index);
                DeselectAnnotation();
                RenderAnnotations();
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

    // ---- 吸附线 / 放大镜 / 悬停高亮 ----

    private static Rectangle MakeGuideLine(bool vertical)
    {
        var brush = new SolidColorBrush(Color.FromRgb(0x1E, 0x88, 0xE5));
        return vertical
            ? new Rectangle { Width = 1, Fill = brush, Visibility = Visibility.Collapsed, IsHitTestVisible = false }
            : new Rectangle { Height = 1, Fill = brush, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    }

    private static (Border, Image, TextBlock) BuildLoupe()
    {
        var image = new Image { Width = 120, Height = 120 };
        // 像素级放大必须用邻近采样：默认的双线性会把 15×15 糊成一片
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        var label = new TextBlock
        {
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0xC0, 0x30, 0x30, 0x30)),
            Padding = new Thickness(6, 2, 6, 2),
            FontSize = 11,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var loupe = new Border
        {
            Child = new StackPanel { Children = { image, label } },
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x66, 0x66, 0x66)),
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(0x40, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Width = 126,
        };
        return (loupe, image, label);
    }

    private void UpdateMagnifier(Point cursorDip)
    {
        var scale = _capture.DpiScale;
        var px = (int)Math.Round(cursorDip.X * scale);
        var py = (int)Math.Round(cursorDip.Y * scale);
        const int side = 15;

        var width = Math.Min(side, _capture.PixelWidth);
        var height = Math.Min(side, _capture.PixelHeight);
        var srcX = Math.Clamp(px - side / 2, 0, Math.Max(0, _capture.PixelWidth - width));
        var srcY = Math.Clamp(py - side / 2, 0, Math.Max(0, _capture.PixelHeight - height));
        _loupeImage.Source = new CroppedBitmap(_capture.Image, new Int32Rect(srcX, srcY, width, height));
        _loupeLabel.Text = HexAt(px, py);
        _loupe.Visibility = Visibility.Visible;
        PlaceNearCursor(cursorDip, _loupe, 126, 152);
    }

    /// <summary>光标处像素的 HEX。越界不崩。</summary>
    private string HexAt(int px, int py)
    {
        if (px < 0 || py < 0 || px >= _capture.PixelWidth || py >= _capture.PixelHeight)
            return "#??????";
        var bytes = new byte[4];
        _capture.Image.CopyPixels(new Int32Rect(px, py, 1, 1), bytes, 4, 0);
        // Bgr32 的内存序是 B,G,R,x
        return $"#{bytes[2]:X2}{bytes[1]:X2}{bytes[0]:X2}";
    }

    /// <summary>默认放光标右下，放不下翻到左/上，最后钳进容器（对齐 macOS Magnifier.frame）。</summary>
    private void PlaceNearCursor(Point cursor, FrameworkElement element, double width, double height)
    {
        const double gap = 18;
        var x = cursor.X + gap;
        if (x + width > ActualWidth) x = cursor.X - gap - width;
        var y = cursor.Y + gap;
        if (y + height > ActualHeight) y = cursor.Y - gap - height;
        Canvas.SetLeft(element, Math.Clamp(x, 0, Math.Max(0, ActualWidth - width)));
        Canvas.SetTop(element, Math.Clamp(y, 0, Math.Max(0, ActualHeight - height)));
    }

    private void UpdateHoverHighlight(Point point)
    {
        if (SelectionSnapping.TopmostWindowContaining(point.X, point.Y, _windowRects) is not { } window)
        {
            _hoverHighlight.Visibility = Visibility.Collapsed;
            return;
        }

        Canvas.SetLeft(_hoverHighlight, window.Left);
        Canvas.SetTop(_hoverHighlight, window.Top);
        _hoverHighlight.Width = window.Width;
        _hoverHighlight.Height = window.Height;
        _hoverHighlight.Visibility = Visibility.Visible;
    }

    private void HideSelectionAids()
    {
        _hoverHighlight.Visibility = Visibility.Collapsed;
        _loupe.Visibility = Visibility.Collapsed;
        _guideV.Visibility = Visibility.Collapsed;
        _guideH.Visibility = Visibility.Collapsed;
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
            _downPoint = point;
            _clickCandidate = SelectionSnapping.TopmostWindowContaining(point.X, point.Y, _windowRects);
            _start = point;
            _dragging = true;
            _hoverHighlight.Visibility = Visibility.Collapsed;
            _selectionRect.Visibility = Visibility.Visible;
            _frozen.Visibility = Visibility.Visible;
            _toolPanel.Visibility = Visibility.Collapsed;
            _actionPanel.Visibility = Visibility.Collapsed;
            UpdateSelection(point);
            CaptureMouse();
            return;
        }

        if (_activeTool == CaptureTool.None || !_selection.Contains(point))
        {
            // 没激活绘制工具：允许点选/拖动已有标注
            if (_selection.Contains(point))
                HandleAnnotationEditMouseDown(new Point(point.X - _selection.X, point.Y - _selection.Y));
            return;
        }

        var localPoint = new Point(point.X - _selection.X, point.Y - _selection.Y);

        // 工具激活时点中已有标注 = 编辑它，否则画新的
        if (HitAnnotation(localPoint) is { } hitIndex)
        {
            BeginEdit(hitIndex, localPoint);
            return;
        }

        DeselectAnnotation();
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

        if (!_selected)
        {
            // 放大镜常驻跟随；没在拖动时还要管悬停高亮
            UpdateMagnifier(point);
            if (!_dragging)
            {
                UpdateHoverHighlight(point);
                return;
            }

            UpdateSelection(point);
            return;
        }

        // 编辑拖动优先于画新标注：正在移动/缩放标注时不去更新预览形状。
        // 注意编辑模式不设置 _dragging，所以要在它的检查之前
        if (_editMode != EditMode.None)
        {
            UpdateEditDrag(new Point(point.X - _selection.X, point.Y - _selection.Y));
            return;
        }

        if (!_dragging) return;

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
        if (_editMode != EditMode.None)
        {
            _editMode = EditMode.None;
            ReleaseMouseCapture();
            return;
        }

        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();

        if (!_selected)
        {
            var distancePx = (e.GetPosition(this) - _downPoint).Length * _capture.DpiScale;

            // 几乎没拖 = 点击：智能选窗 —— 直接选中悬停高亮的那个窗口
            if (distancePx < 3 && _clickCandidate is { } candidate)
            {
                _selection = new Rect(candidate.X, candidate.Y, candidate.Width, candidate.Height);
                DrawSelection();
                HideSelectionAids();
                _selected = true;
                FinishSelection();
                return;
            }

            // 小于 3x3 像素视为误触（与 Core 的 CaptureGeometry 同一约定）
            if (_selection.Width * _capture.DpiScale < 3 || _selection.Height * _capture.DpiScale < 3)
            {
                _selectionRect.Visibility = Visibility.Collapsed;
                _frozen.Visibility = Visibility.Hidden;
                _sizeHint.Visibility = Visibility.Collapsed;
                HideSelectionAids();
                return;
            }

            HideSelectionAids();
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
                _selectedAnnotation = _annotations.Count - 1;
                _editIndex = _selectedAnnotation.Value;
                UpdateSelectionVisual();
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
        // 边缘吸附到窗口边界 / 屏幕边界，辅助线指出吸上了哪条
        var raw = SnapRect.FromPoints(_start.X, _start.Y, current.X, current.Y);
        var snapped = SelectionSnapping.Snap(raw, _snapTargets);
        _selection = new Rect(snapped.Rect.X, snapped.Rect.Y, snapped.Rect.Width, snapped.Rect.Height);
        DrawSelection();
        UpdateSnapGuides(snapped);
    }

    private void DrawSelection()
    {
        Canvas.SetLeft(_selectionRect, _selection.Left);
        Canvas.SetTop(_selectionRect, _selection.Top);
        _selectionRect.Width = _selection.Width;
        _selectionRect.Height = _selection.Height;

        // 选区内"亮起来"：把冻结原图裁到选区，盖在暗层上面（标注阶段换成画布位图）
        _frozen.Clip = new RectangleGeometry(_selection);

        Canvas.SetLeft(_sizeHint, _selection.Left);
        Canvas.SetTop(_sizeHint, _selection.Top + _selection.Height + 6);
        _sizeHint.Text = $"{(int)(_selection.Width * _capture.DpiScale)} × {(int)(_selection.Height * _capture.DpiScale)}";
        _sizeHint.Visibility = Visibility.Visible;
    }

    private void UpdateSnapGuides(SnappedSelection snapped)
    {
        if (snapped.SnappedEdges.Contains(SnapEdge.Left) || snapped.SnappedEdges.Contains(SnapEdge.Right))
        {
            var x = snapped.SnappedEdges.Contains(SnapEdge.Left) ? _selection.Left : _selection.Right;
            Canvas.SetLeft(_guideV, x);
            Canvas.SetTop(_guideV, 0);
            _guideV.Height = ActualHeight;
            _guideV.Visibility = Visibility.Visible;
        }
        else _guideV.Visibility = Visibility.Collapsed;

        if (snapped.SnappedEdges.Contains(SnapEdge.Top) || snapped.SnappedEdges.Contains(SnapEdge.Bottom))
        {
            var y = snapped.SnappedEdges.Contains(SnapEdge.Top) ? _selection.Top : _selection.Bottom;
            Canvas.SetTop(_guideH, y);
            Canvas.SetLeft(_guideH, 0);
            _guideH.Width = ActualWidth;
            _guideH.Visibility = Visibility.Visible;
        }
        else _guideH.Visibility = Visibility.Collapsed;
    }

    /// <summary>选区确定：裁出底图，建画布位图，显示工具栏并默认选中矩形工具。</summary>
    private void FinishSelection()
    {
        HideSelectionAids();
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
        RunAutomaticActions();
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

        var blockSize = Math.Max(4, (int)(_settings.MosaicBlockSize * _capture.DpiScale));
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

    /// <summary>提交：预览形状移除，标注进列表并栅格化进画布位图；顺手选中它方便接着调。</summary>
    private void CommitPreview(Annotation annotation)
    {
        ClearPreview();
        _annotations.Add(annotation);
        RenderAnnotations();
        _selectedAnnotation = _annotations.Count - 1;
        _editIndex = _selectedAnnotation.Value;
        UpdateSelectionVisual();
    }

    private void Undo()
    {
        if (_annotations.Count == 0) return;
        _annotations.RemoveAt(_annotations.Count - 1);
        DeselectAnnotation();
        RenderAnnotations();
    }

    // ---- 标注编辑 ----

    private const double GrabRadius = 6;

    /// <summary>标注的包围盒（选区内 DIP）。文字没有精确宽高，用近似框。</summary>
    private static Rect AnnotationBoundsOf(Annotation annotation) => annotation switch
    {
        RectNote r => r.R,
        EllipseNote e => e.R,
        MosaicNote m => m.R,
        ArrowNote a => RectFrom(a.From, a.To),
        PenNote p => RectFrom(p.Points[0], p.Points[^1]) is var seed
            ? UnionAll(seed, p.Points)
            : default,
        TextNote t => new Rect(t.Position.X, t.Position.Y, Math.Max(24, t.Text.Length * 8.4), 20),
        _ => default,
    };

    private static Rect UnionAll(Rect seed, IReadOnlyList<Point> points)
    {
        var result = seed;
        foreach (var point in points) result.Union(point);
        return result;
    }

    private int? HitAnnotation(Point local)
    {
        var tolerance = NoteThickness;
        for (var i = _annotations.Count - 1; i >= 0; i--)
        {
            var bounds = AnnotationBoundsOf(_annotations[i]);
            var hit = _annotations[i] switch
            {
                EllipseNote ellipse => AnnotationHitTest.HitEllipse(local.X, local.Y,
                    new SnapRect(bounds.X, bounds.Y, bounds.Width, bounds.Height), tolerance),
                ArrowNote arrow => AnnotationHitTest.HitPolyline(local.X, local.Y,
                    [(arrow.From.X, arrow.From.Y), (arrow.To.X, arrow.To.Y)], tolerance),
                PenNote pen => AnnotationHitTest.HitPolyline(local.X, local.Y,
                    pen.Points.Select(pt => (pt.X, pt.Y)).ToList(), tolerance),
                _ => AnnotationHitTest.HitRect(local.X, local.Y,
                    new SnapRect(bounds.X, bounds.Y, bounds.Width, bounds.Height), tolerance),
            };
            if (hit) return i;
        }
        return null;
    }

    private void HandleAnnotationEditMouseDown(Point local)
    {
        // 已选中标注的角柄优先（缩放），再试命中（选中并移动），最后取消选中
        if (_selectedAnnotation is { } index && index < _annotations.Count)
        {
            var bounds = AnnotationBoundsOf(_annotations[index]);
            if (AnnotationHitTest.NearestCorner(local.X, local.Y,
                    new SnapRect(bounds.X, bounds.Y, bounds.Width, bounds.Height), GrabRadius) is { } corner)
            {
                _editIndex = index;
                _editMode = EditMode.Resize;
                _resizeCorner = corner.Corner;
                _editStartLocal = local;
                _editStartBounds = bounds;
                CaptureMouse();
                return;
            }
        }

        if (HitAnnotation(local) is { } hit)
        {
            BeginEdit(hit, local);
            return;
        }

        DeselectAnnotation();
    }

    private void BeginEdit(int index, Point local)
    {
        _selectedAnnotation = index;
        _editIndex = index;
        _editMode = EditMode.Move;
        _resizeCorner = -1;
        _editStartLocal = local;
        _editStartBounds = AnnotationBoundsOf(_annotations[index]);
        UpdateSelectionVisual();
        CaptureMouse();
    }

    private void UpdateEditDrag(Point local)
    {
        if (_editIndex < 0 || _editIndex >= _annotations.Count) return;
        var dx = local.X - _editStartLocal.X;
        var dy = local.Y - _editStartLocal.Y;

        if (_editMode == EditMode.Move)
        {
            var bounds = _editStartBounds;
            _annotations[_editIndex] = _annotations[_editIndex] switch
            {
                RectNote r => r with { R = Offset(r.R, dx, dy) },
                EllipseNote en => en with { R = Offset(en.R, dx, dy) },
                MosaicNote m => m with { R = Offset(m.R, dx, dy) },
                ArrowNote a => a with { From = Add(a.From, dx, dy), To = Add(a.To, dx, dy) },
                PenNote p => p with { Points = p.Points.Select(pt => Add(pt, dx, dy)).ToList() },
                TextNote t => t with { Position = Add(t.Position, dx, dy) },
                _ => _annotations[_editIndex],
            };
        }
        else
        {
            // 角柄缩放：拖动的角跟随鼠标，对角固定；小于 4x4 就不再收缩
            var left = _editStartBounds.Left;
            var top = _editStartBounds.Top;
            var right = _editStartBounds.Right;
            var bottom = _editStartBounds.Bottom;
            if (_resizeCorner is 0 or 3) left = Math.Min(local.X, right - 4);
            if (_resizeCorner is 1 or 2) right = Math.Max(local.X, left + 4);
            if (_resizeCorner is 0 or 1) top = Math.Min(local.Y, bottom - 4);
            if (_resizeCorner is 2 or 3) bottom = Math.Max(local.Y, top + 4);
            var resized = RectFrom(new Point(left, top), new Point(right, bottom));
            _annotations[_editIndex] = _annotations[_editIndex] switch
            {
                RectNote r => r with { R = resized },
                EllipseNote en => en with { R = resized },
                MosaicNote m => m with { R = resized },
                _ => _annotations[_editIndex],
            };
        }

        RenderAnnotations();
        UpdateSelectionVisual();
        return;

        static Rect Offset(Rect rect, double dx, double dy) =>
            new(rect.X + dx, rect.Y + dy, rect.Width, rect.Height);

        static Point Add(Point point, double dx, double dy) => new(point.X + dx, point.Y + dy);
    }

    private void UpdateSelectionVisual()
    {
        if (_selectedAnnotation is not { } index || index >= _annotations.Count)
        {
            DeselectAnnotation();
            return;
        }

        var bounds = AnnotationBoundsOf(_annotations[index]);
        Canvas.SetLeft(_editFrame, bounds.Left);
        Canvas.SetTop(_editFrame, bounds.Top);
        _editFrame.Width = bounds.Width;
        _editFrame.Height = bounds.Height;
        _editFrame.Visibility = Visibility.Visible;

        // 文字/画笔/箭头不支持缩放：只给移动虚线框，不给角柄
        var resizable = _annotations[index] is RectNote or EllipseNote or MosaicNote;
        foreach (var (corner, x, y) in AnnotationHitTest.Corners(
                     new SnapRect(bounds.X, bounds.Y, bounds.Width, bounds.Height)))
        {
            var handle = _editHandles[corner];
            handle.Visibility = resizable ? Visibility.Visible : Visibility.Collapsed;
            Canvas.SetLeft(handle, x - handle.Width / 2);
            Canvas.SetTop(handle, y - handle.Height / 2);
        }

        _editCanvas.Visibility = Visibility.Visible;
    }

    private void DeselectAnnotation()
    {
        _selectedAnnotation = null;
        _editIndex = -1;
        _editMode = EditMode.None;
        _editCanvas.Visibility = Visibility.Collapsed;
        _editFrame.Visibility = Visibility.Collapsed;
        foreach (var handle in _editHandles) handle.Visibility = Visibility.Collapsed;
    }

    // ---- 导出动作 ----

    private BitmapSource? ExportImage()
    {
        if (!_selected || _canvasBitmap is null) return null;
        return _canvasBitmap;
    }

    /// <summary>选区确认：按设置的自动动作依次执行，有任何一个生效就关窗。</summary>
    private void RunAutomaticActions()
    {
        if (!_settings.CopyAfterCapture && !_settings.PinAfterCapture && !_settings.SaveToPictures) return;

        var acted = false;
        if (_settings.CopyAfterCapture) acted |= DoCopy();
        if (_settings.SaveToPictures) acted |= DoAutoSave();
        if (_settings.PinAfterCapture) acted |= DoPin();
        if (acted) Close();
    }

    private void CopySelection()
    {
        if (DoCopy()) Close();
    }

    private bool DoCopy()
    {
        var image = ExportImage();
        if (image is null) return false;
        try
        {
            // 截图复制是真实复制，应该进历史，不打自写标记
            System.Windows.Clipboard.SetImage(image);
            _onCopy(image);
            return true;
        }
        catch (Exception error)
        {
            _report($"复制截图失败：{error.Message}");
            return false;
        }
    }

    private void PinSelection()
    {
        if (DoPin()) Close();
    }

    private bool DoPin()
    {
        var image = ExportImage();
        if (image is null) return false;
        _onPin(image, SelectionScreenRect());
        return true;
    }

    private void SaveSelection()
    {
        var image = ExportImage();
        if (image is null) return;

        var dialog = new SaveFileDialog
        {
            Filter = "PNG 图片|*.png",
            FileName = $"Toolbox-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            InitialDirectory = _settings.SaveDirectory.Length > 0
                ? _settings.SaveDirectory
                : Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            SavePng(image, dialog.FileName);
            _report($"截图已保存：{dialog.FileName}");
            Close();
        }
        catch (Exception error)
        {
            _report($"保存失败：{error.Message}");
        }
    }

    /// <summary>自动保存：不弹对话框，直接落盘到固定目录。</summary>
    private bool DoAutoSave()
    {
        var image = ExportImage();
        if (image is null) return false;

        try
        {
            var directory = _settings.SaveDirectory.Length > 0
                ? _settings.SaveDirectory
                : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Toolbox");
            Directory.CreateDirectory(directory);
            var file = System.IO.Path.Combine(directory, $"Toolbox-{DateTime.Now:yyyyMMdd-HHmmss}.png");
            SavePng(image, file);
            _report($"截图已保存：{file}");
            return true;
        }
        catch (Exception error)
        {
            _report($"自动保存失败：{error.Message}");
            return false;
        }
    }

    private static void SavePng(BitmapSource image, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = File.Create(path);
        encoder.Save(stream);
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
