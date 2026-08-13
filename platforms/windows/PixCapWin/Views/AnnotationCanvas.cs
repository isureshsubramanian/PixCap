using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace PixCapWin.Views;

/// <summary>
/// Interactive annotation surface.
///
/// Mirrors the macOS editor's split: committed annotations are drawn by the
/// Rust renderer into the preview image beneath, while the shape currently
/// under the pointer is drawn here with XAML shapes so dragging stays
/// responsive. On release the item is committed and the preview re-renders,
/// so what you see is always the renderer's own output.
/// </summary>
public sealed class AnnotationCanvas : Canvas
{
    private readonly AnnotationStore _store;

    private AnnotationItem? _draft;
    private Point? _moveAnchor;
    private bool _dragging;
    private bool _previewIsStale;

    /// <summary>
    /// Whether the preview underneath is a render behind the store.
    ///
    /// Committed annotations normally come from the rendered preview, so the
    /// overlay drops them the moment they are committed. That leaves them
    /// invisible until the next render arrives — the whole reason annotations
    /// looked like they vanished. While this is set, the overlay keeps drawing
    /// them itself, so the handover happens without a gap.
    /// </summary>
    public bool PreviewIsStale
    {
        get => _previewIsStale;
        set
        {
            if (_previewIsStale == value) return;
            _previewIsStale = value;
            Redraw();
        }
    }

    /// <summary>Geometry from the renderer, mapping image space to the canvas.</summary>
    public RenderLayout? Layout { get; set; }

    /// <summary>Scale from canvas points to on-screen pixels.</summary>
    public double DisplayScale { get; set; } = 1.0;

    private AnnotationTool _tool = AnnotationTool.Select;

    /// <summary>
    /// The active tool. Setting it also sets the pointer, because a crosshair
    /// over a drawing surface is how you know the drag will draw rather than
    /// select — the same reason the macOS overlay works so hard to hold one.
    /// </summary>
    public AnnotationTool Tool
    {
        get => _tool;
        set
        {
            _tool = value;
            ApplyCursor();
        }
    }

    public string ColorHex { get; set; } = "#FF3366";
    public double StrokeWidth { get; set; } = 4;
    public bool Filled { get; set; }
    public bool Dashed { get; set; }
    public string ArrowHead { get; set; } = "filled";
    public string BlurStyle { get; set; } = "pixelate";
    public double FontSize { get; set; } = 28;

    /// <summary>Raised when the layer changes and the preview needs re-rendering.</summary>
    public event EventHandler? LayerChanged;

    /// <summary>Raised when a text annotation needs its content typed in.</summary>
    public event EventHandler<AnnotationItem>? TextRequested;

    /// <summary>Raised when the crop tool produces a rectangle.</summary>
    public event EventHandler<Rect>? CropRequested;

    public AnnotationCanvas(AnnotationStore store)
    {
        _store = store;
        Background = new SolidColorBrush(Colors.Transparent);
        IsHitTestVisible = true;

        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerCanceled += (_, _) => EndDrag();
        PointerCaptureLost += (_, _) => EndDrag();

        ApplyCursor();
    }

    /// <summary>
    /// Matches the pointer to the tool.
    ///
    /// Child shapes added during a drag leave their own cursor unset, so they
    /// inherit this one and the crosshair does not flicker back to an arrow as
    /// the pointer crosses whatever is being drawn.
    /// </summary>
    private void ApplyCursor()
    {
        var shape = _tool switch
        {
            AnnotationTool.Select => InputSystemCursorShape.Arrow,
            AnnotationTool.Text => InputSystemCursorShape.IBeam,
            _ => InputSystemCursorShape.Cross
        };

        ProtectedCursor = InputSystemCursor.Create(shape);
    }

    // MARK: - Coordinate mapping

    /// <summary>Converts a pointer position into uncropped image space.</summary>
    private Point ToImageSpace(Point screen)
    {
        if (Layout is null || DisplayScale <= 0) return screen;

        var canvasX = screen.X / DisplayScale;
        var canvasY = screen.Y / DisplayScale;

        var x = canvasX - Layout.ImageX + Layout.CropX;
        var y = canvasY - Layout.ImageY + Layout.CropY;

        // Clamp to the visible image so annotations cannot land off-canvas.
        return new Point(
            Math.Clamp(x, Layout.CropX, Layout.CropX + Layout.ImageWidth),
            Math.Clamp(y, Layout.CropY, Layout.CropY + Layout.ImageHeight));
    }

    /// <summary>Converts image space back to on-screen coordinates.</summary>
    private Point ToScreen(Point image)
    {
        if (Layout is null) return image;

        return new Point(
            (image.X - Layout.CropX + Layout.ImageX) * DisplayScale,
            (image.Y - Layout.CropY + Layout.ImageY) * DisplayScale);
    }

    // MARK: - Pointer handling

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var position = ToImageSpace(e.GetCurrentPoint(this).Position);
        _dragging = true;
        CapturePointer(e.Pointer);

        switch (Tool)
        {
            case AnnotationTool.Select:
                var hit = _store.HitTest(position);
                _store.SelectedId = hit?.Id;
                if (hit is not null)
                {
                    _store.Checkpoint();
                    _moveAnchor = position;
                }
                Redraw();
                break;

            case AnnotationTool.Text:
            case AnnotationTool.Counter:
                break; // placed on release

            default:
                _draft = NewItem(position, position);
                break;
        }
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;

        var position = ToImageSpace(e.GetCurrentPoint(this).Position);

        if (Tool == AnnotationTool.Select)
        {
            if (_moveAnchor is not { } anchor || _store.SelectedId is not { } id) return;

            var selected = _store.Find(id);
            if (selected is null) return;

            _store.Replace(selected.MovedBy(position.X - anchor.X, position.Y - anchor.Y));
            _moveAnchor = position;
            Redraw();
            return;
        }

        if (_draft is null) return;

        if (Tool == AnnotationTool.Freehand)
        {
            _draft.Points.Add(position);
        }
        _draft.End = position;

        Redraw();
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;

        var position = ToImageSpace(e.GetCurrentPoint(this).Position);

        // Take the draft and end the drag *before* releasing capture.
        //
        // ReleasePointerCapture raises PointerCaptureLost synchronously, and
        // that handler abandons the drag — including the draft. Reading _draft
        // after the release therefore always found null, so every annotation
        // drawn by dragging was thrown away the instant the pointer came up.
        // Only the tools placed by a single click, Counter and Text, survived,
        // because they build their item from the release position instead.
        var draft = _draft;
        _draft = null;
        _dragging = false;
        ReleasePointerCapture(e.Pointer);

        switch (Tool)
        {
            case AnnotationTool.Select:
                _moveAnchor = null;
                LayerChanged?.Invoke(this, EventArgs.Empty);
                break;

            case AnnotationTool.Crop:
                if (draft is not null && draft.IsMeaningful)
                {
                    CropRequested?.Invoke(this, draft.Bounds);
                }
                Redraw();
                break;

            case AnnotationTool.Counter:
                var counter = NewItem(position, position);
                counter.Number = _store.NextCounter;
                _store.Add(counter);
                LayerChanged?.Invoke(this, EventArgs.Empty);
                break;

            case AnnotationTool.Text:
                var text = NewItem(position, position);
                text.FontSize = FontSize;
                TextRequested?.Invoke(this, text);
                break;

            default:
                if (draft is not null && draft.IsMeaningful)
                {
                    _store.Add(draft);
                    LayerChanged?.Invoke(this, EventArgs.Empty);
                }
                Redraw();
                break;
        }
    }

    private void EndDrag()
    {
        _dragging = false;
        _draft = null;
        _moveAnchor = null;
        Redraw();
    }

    private AnnotationItem NewItem(Point start, Point end) => new()
    {
        Tool = Tool == AnnotationTool.Crop ? AnnotationTool.Rectangle : Tool,
        Start = start,
        End = end,
        Points = Tool == AnnotationTool.Freehand ? [start] : [],
        ColorHex = ColorHex,
        StrokeWidth = StrokeWidth,
        Filled = Filled,
        Dashed = Dashed,
        ArrowHead = ArrowHead,
        BlurStyle = BlurStyle,
        FontSize = FontSize
    };

    // MARK: - Drawing

    /// <summary>
    /// Redraws the overlay: the in-progress shape, plus outlines for the
    /// selection and for blur regions, which have no stroke of their own and
    /// would otherwise be invisible until rendered.
    /// </summary>
    public void Redraw()
    {
        Children.Clear();
        if (Layout is null) return;

        if (PreviewIsStale)
        {
            foreach (var item in _store.Items)
            {
                AddCommitted(item);
            }
        }

        foreach (var item in _store.Items.Where(item => item.Tool == AnnotationTool.Blur))
        {
            AddOutline(item.Bounds, Color.FromArgb(140, 255, 255, 255));
        }

        if (_store.SelectedId is { } id && _store.Find(id) is { } selected)
        {
            AddOutline(selected.HitBounds(), Color.FromArgb(220, 0, 120, 215));
        }

        if (_draft is null) return;

        if (Tool == AnnotationTool.Crop || _draft.Tool == AnnotationTool.Blur)
        {
            AddOutline(_draft.Bounds, Color.FromArgb(220, 255, 255, 255));
            return;
        }

        AddDraftShape(_draft);
    }

    private void AddOutline(Rect imageBounds, Color color)
    {
        var topLeft = ToScreen(new Point(imageBounds.X, imageBounds.Y));
        var size = new Size(imageBounds.Width * DisplayScale, imageBounds.Height * DisplayScale);

        var outline = new Rectangle
        {
            Width = Math.Max(1, size.Width),
            Height = Math.Max(1, size.Height),
            Stroke = new SolidColorBrush(color),
            StrokeThickness = 1.5,
            StrokeDashArray = [4, 3],
            Fill = new SolidColorBrush(Colors.Transparent)
        };

        SetLeft(outline, topLeft.X);
        SetTop(outline, topLeft.Y);
        Children.Add(outline);
    }

    /// <summary>
    /// Stands in for one committed annotation while the preview catches up.
    ///
    /// This is deliberately an approximation of the renderer's output, not a
    /// second implementation of it: it is on screen for the length of one
    /// render, and the renderer's own version replaces it.
    /// </summary>
    private void AddCommitted(AnnotationItem item)
    {
        switch (item.Tool)
        {
            case AnnotationTool.Blur:
                return; // Already outlined below, and the pixels come from the renderer.

            case AnnotationTool.Counter:
                var radius = Math.Max(item.StrokeWidth * 6, 14) * DisplayScale;
                var centre = ToScreen(item.Start);
                var bubble = new Ellipse
                {
                    Width = radius * 2,
                    Height = radius * 2,
                    Fill = new SolidColorBrush(ParseColor(item.ColorHex))
                };
                SetLeft(bubble, centre.X - radius);
                SetTop(bubble, centre.Y - radius);
                Children.Add(bubble);
                AddLabel(item.Number.ToString(), centre, radius, Colors.White, centred: true);
                return;

            case AnnotationTool.Text:
                if (item.Text.Length == 0) return;
                AddLabel(item.Text, ToScreen(item.Start), item.FontSize * DisplayScale,
                         ParseColor(item.ColorHex), centred: false);
                return;

            default:
                AddDraftShape(item);
                return;
        }
    }

    private void AddLabel(string text, Point at, double fontSize, Color color, bool centred)
    {
        var label = new TextBlock
        {
            Text = text,
            FontSize = Math.Max(1, fontSize),
            Foreground = new SolidColorBrush(color)
        };

        // A TextBlock only knows its size once measured.
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));

        SetLeft(label, centred ? at.X - label.DesiredSize.Width / 2 : at.X);
        SetTop(label, centred ? at.Y - label.DesiredSize.Height / 2 : at.Y);
        Children.Add(label);
    }

    private void AddDraftShape(AnnotationItem item)
    {
        var brush = new SolidColorBrush(ParseColor(item.ColorHex));
        var thickness = Math.Max(1, item.StrokeWidth * DisplayScale);
        var start = ToScreen(item.Start);
        var end = ToScreen(item.End);

        var bounds = item.Bounds;
        var topLeft = ToScreen(new Point(bounds.X, bounds.Y));
        var width = Math.Max(1, bounds.Width * DisplayScale);
        var height = Math.Max(1, bounds.Height * DisplayScale);

        Shape? shape = item.Tool switch
        {
            AnnotationTool.Rectangle or AnnotationTool.Highlight or
            AnnotationTool.Redaction or AnnotationTool.Spotlight => new Rectangle
            {
                Width = width,
                Height = height,
                Stroke = brush,
                StrokeThickness = thickness,
                Fill = FillBrush(item)
            },

            AnnotationTool.Ellipse => new Ellipse
            {
                Width = width,
                Height = height,
                Stroke = brush,
                StrokeThickness = thickness,
                Fill = FillBrush(item)
            },

            AnnotationTool.Line or AnnotationTool.Arrow => new Line
            {
                X1 = start.X, Y1 = start.Y, X2 = end.X, Y2 = end.Y,
                Stroke = brush,
                StrokeThickness = thickness,
                StrokeEndLineCap = PenLineCap.Round
            },

            AnnotationTool.Freehand => BuildPolyline(item, brush, thickness),

            _ => null
        };

        if (shape is null) return;

        if (item.Dashed) shape.StrokeDashArray = [3, 2];

        // Lines carry absolute coordinates; everything else is positioned.
        if (shape is not Line && shape is not Polyline)
        {
            SetLeft(shape, topLeft.X);
            SetTop(shape, topLeft.Y);
        }

        Children.Add(shape);
    }

    private Polyline BuildPolyline(AnnotationItem item, Brush brush, double thickness)
    {
        var polyline = new Polyline
        {
            Stroke = brush,
            StrokeThickness = thickness,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round
        };

        foreach (var point in item.Points)
        {
            polyline.Points.Add(ToScreen(point));
        }

        return polyline;
    }

    private Brush FillBrush(AnnotationItem item)
    {
        if (item.Tool == AnnotationTool.Redaction)
        {
            return new SolidColorBrush(ParseColor(item.ColorHex));
        }

        if (item.Tool is AnnotationTool.Highlight || item.Filled)
        {
            var color = ParseColor(item.ColorHex);
            return new SolidColorBrush(Color.FromArgb(90, color.R, color.G, color.B));
        }

        return new SolidColorBrush(Colors.Transparent);
    }

    public static Color ParseColor(string hex)
    {
        var value = hex.TrimStart('#');
        if (value.Length == 6) value = "FF" + value;
        if (value.Length != 8 || !uint.TryParse(value, System.Globalization.NumberStyles.HexNumber,
                                                null, out var packed))
        {
            return Colors.Red;
        }

        return Color.FromArgb(
            (byte)((packed >> 24) & 0xFF),
            (byte)((packed >> 16) & 0xFF),
            (byte)((packed >> 8) & 0xFF),
            (byte)(packed & 0xFF));
    }
}

/// <summary>Canvas geometry reported by the renderer.</summary>
public sealed class RenderLayout
{
    public double CanvasWidth { get; set; }
    public double CanvasHeight { get; set; }
    public double ImageX { get; set; }
    public double ImageY { get; set; }
    public double ImageWidth { get; set; }
    public double ImageHeight { get; set; }
    public double CropX { get; set; }
    public double CropY { get; set; }
}
