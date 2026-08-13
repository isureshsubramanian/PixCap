using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using Windows.Foundation;

namespace PixCapWin.Views;

/// <summary>
/// Tools the annotation editor offers.
///
/// Names match the strings the Rust renderer expects, so an item serialises
/// straight into the shared document schema without translation.
/// </summary>
public enum AnnotationTool
{
    Select,
    Crop,
    Rectangle,
    Ellipse,
    Line,
    Arrow,
    Freehand,
    Highlight,
    Text,
    Counter,
    Blur,
    Redaction,
    Spotlight
}

public static class AnnotationToolExtensions
{
    /// <summary>The identifier the renderer uses.</summary>
    public static string ToToken(this AnnotationTool tool) => tool switch
    {
        AnnotationTool.Select => "select",
        AnnotationTool.Crop => "crop",
        AnnotationTool.Rectangle => "rectangle",
        AnnotationTool.Ellipse => "ellipse",
        AnnotationTool.Line => "line",
        AnnotationTool.Arrow => "arrow",
        AnnotationTool.Freehand => "freehand",
        AnnotationTool.Highlight => "highlight",
        AnnotationTool.Text => "text",
        AnnotationTool.Counter => "counter",
        AnnotationTool.Blur => "blur",
        AnnotationTool.Redaction => "redaction",
        AnnotationTool.Spotlight => "spotlight",
        _ => "rectangle"
    };

    /// <summary>
    /// Short palette label. Now the tooltip and the accessible name for the
    /// tool's button, since the button itself shows <see cref="Glyph"/>.
    /// </summary>
    public static string Label(this AnnotationTool tool) => tool switch
    {
        AnnotationTool.Select => "Select",
        AnnotationTool.Crop => "Crop",
        AnnotationTool.Rectangle => "Rectangle",
        AnnotationTool.Ellipse => "Ellipse",
        AnnotationTool.Line => "Line",
        AnnotationTool.Arrow => "Arrow",
        AnnotationTool.Freehand => "Draw",
        AnnotationTool.Highlight => "Highlight",
        AnnotationTool.Text => "Text",
        AnnotationTool.Counter => "Counter",
        AnnotationTool.Blur => "Blur",
        AnnotationTool.Redaction => "Redaction",
        AnnotationTool.Spotlight => "Spotlight",
        _ => tool.ToString()
    };

    /// <summary>
    /// Segoe Fluent Icons code point for the palette button.
    ///
    /// Every one of these was rendered and looked at before being chosen — a
    /// glyph that turns out to be the wrong picture is worse than a word, and
    /// the code point alone does not tell you which picture you get. The label
    /// stays as the tooltip and the accessible name, so nothing is lost to
    /// someone who does not recognise an icon.
    /// </summary>
    public static string Glyph(this AnnotationTool tool) => tool switch
    {
        AnnotationTool.Select => "\uE8B0",      // pointer
        AnnotationTool.Crop => "\uE7A8",        // crop marks
        AnnotationTool.Rectangle => "\uE739",   // empty square
        AnnotationTool.Ellipse => "\uEA3A",     // empty circle
        AnnotationTool.Line => "\uE738",        // horizontal rule
        AnnotationTool.Arrow => "\uE72A",       // arrow
        AnnotationTool.Freehand => "\uEC87",    // pencil drawing a stroke
        AnnotationTool.Highlight => "\uE7E6",   // highlighter
        AnnotationTool.Text => "\uE97F",        // letter A
        AnnotationTool.Counter => "\uF146",     // numeral 1
        AnnotationTool.Blur => "\uEB42",        // droplet
        AnnotationTool.Redaction => "\uE73B",   // filled block
        AnnotationTool.Spotlight => "\uEC8A",   // sun
        _ => "\uE739"
    };

    /// <summary>Tools placed with a single click rather than dragged out.</summary>
    public static bool IsPointPlaced(this AnnotationTool tool) =>
        tool is AnnotationTool.Text or AnnotationTool.Counter;
}

/// <summary>
/// One annotation, in image-space points with a top-left origin — the same
/// coordinate system the renderer and the macOS editor use, so a document
/// written on either platform means the same thing.
/// </summary>
public sealed class AnnotationItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public AnnotationTool Tool { get; set; }
    public Point Start { get; set; }
    public Point End { get; set; }
    public List<Point> Points { get; set; } = [];
    public string ColorHex { get; set; } = "#FF3366";
    public double StrokeWidth { get; set; } = 4;
    public bool Filled { get; set; }
    public string Text { get; set; } = "";
    public double FontSize { get; set; } = 28;
    public int Number { get; set; } = 1;
    public string BlurStyle { get; set; } = "pixelate";
    public double BlurIntensity { get; set; } = 24;
    public bool CurvedArrow { get; set; } = true;
    public string ArrowHead { get; set; } = "filled";
    public bool Dashed { get; set; }
    public double SpotlightDim { get; set; } = 0.65;

    /// <summary>Normalised bounding rectangle.</summary>
    public Rect Bounds => new(
        Math.Min(Start.X, End.X),
        Math.Min(Start.Y, End.Y),
        Math.Abs(End.X - Start.X),
        Math.Abs(End.Y - Start.Y));

    /// <summary>Whether a drag produced something worth keeping.</summary>
    public bool IsMeaningful => Tool switch
    {
        AnnotationTool.Counter => true,
        AnnotationTool.Text => !string.IsNullOrWhiteSpace(Text),
        AnnotationTool.Freehand => Points.Count > 1,
        AnnotationTool.Line or AnnotationTool.Arrow =>
            Math.Sqrt(Math.Pow(End.X - Start.X, 2) + Math.Pow(End.Y - Start.Y, 2)) > 4,
        _ => Bounds.Width > 4 && Bounds.Height > 4
    };

    /// <summary>Hit area for the select tool, padded so thin strokes stay grabbable.</summary>
    public Rect HitBounds()
    {
        var padding = Math.Max(StrokeWidth, 8);

        if (Tool == AnnotationTool.Counter)
        {
            var radius = Math.Max(14, StrokeWidth * 6);
            return new Rect(Start.X - radius, Start.Y - radius, radius * 2, radius * 2);
        }

        if (Tool == AnnotationTool.Text)
        {
            // Approximate: the renderer owns the real metrics.
            var width = Math.Max(20, Text.Length * FontSize * 0.55);
            return new Rect(Start.X - padding, Start.Y - padding,
                            width + padding * 2, FontSize + padding * 2);
        }

        if (Tool == AnnotationTool.Freehand && Points.Count > 0)
        {
            var minX = Points.Min(p => p.X);
            var minY = Points.Min(p => p.Y);
            var maxX = Points.Max(p => p.X);
            var maxY = Points.Max(p => p.Y);
            return new Rect(minX - padding, minY - padding,
                            maxX - minX + padding * 2, maxY - minY + padding * 2);
        }

        var bounds = Bounds;
        return new Rect(bounds.X - padding, bounds.Y - padding,
                        bounds.Width + padding * 2, bounds.Height + padding * 2);
    }

    public AnnotationItem Clone() => new()
    {
        Id = Id,
        Tool = Tool, Start = Start, End = End, Points = [.. Points],
        ColorHex = ColorHex, StrokeWidth = StrokeWidth, Filled = Filled,
        Text = Text, FontSize = FontSize, Number = Number,
        BlurStyle = BlurStyle, BlurIntensity = BlurIntensity,
        CurvedArrow = CurvedArrow, ArrowHead = ArrowHead, Dashed = Dashed,
        SpotlightDim = SpotlightDim
    };

    public AnnotationItem MovedBy(double dx, double dy)
    {
        var copy = Clone();
        copy.Start = new Point(Start.X + dx, Start.Y + dy);
        copy.End = new Point(End.X + dx, End.Y + dy);
        copy.Points = Points.Select(p => new Point(p.X + dx, p.Y + dy)).ToList();
        return copy;
    }

    /// <summary>Serialises into the shared document schema.</summary>
    public JsonObject ToJson() => new()
    {
        ["id"] = Id.ToString(),
        ["tool"] = Tool.ToToken(),
        ["start"] = new JsonArray(Start.X, Start.Y),
        ["end"] = new JsonArray(End.X, End.Y),
        ["points"] = new JsonArray(Points.Select(p => (JsonNode)new JsonArray(p.X, p.Y)).ToArray()),
        ["color_hex"] = ColorHex,
        ["stroke_width"] = StrokeWidth,
        ["filled"] = Filled,
        ["text"] = Text,
        ["font_size"] = FontSize,
        ["number"] = Number,
        ["blur_style"] = BlurStyle,
        ["blur_intensity"] = BlurIntensity,
        ["curved_arrow"] = CurvedArrow,
        ["arrow_head"] = ArrowHead,
        ["dashed"] = Dashed,
        ["spotlight_dim"] = SpotlightDim
    };
}

/// <summary>
/// The annotation layer plus undo/redo history for one editing session.
/// </summary>
public sealed class AnnotationStore
{
    private readonly List<AnnotationItem> _items = [];
    private readonly Stack<List<AnnotationItem>> _undo = new();
    private readonly Stack<List<AnnotationItem>> _redo = new();

    public IReadOnlyList<AnnotationItem> Items => _items;
    public Guid? SelectedId { get; set; }

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public bool IsEmpty => _items.Count == 0;

    /// <summary>Next counter value, continuing from the highest already placed.</summary>
    public int NextCounter
    {
        get
        {
            var placed = _items.Where(item => item.Tool == AnnotationTool.Counter).ToList();
            return placed.Count == 0 ? 1 : placed.Max(item => item.Number) + 1;
        }
    }

    /// <summary>Snapshots current state for undo. Call before any mutation.</summary>
    public void Checkpoint()
    {
        _undo.Push(_items.Select(item => item.Clone()).ToList());
        if (_undo.Count > 50)
        {
            // Stack has no bounded variant; rebuild without the oldest entry.
            var trimmed = _undo.Reverse().Skip(1).ToList();
            _undo.Clear();
            foreach (var state in trimmed) _undo.Push(state);
        }
        _redo.Clear();
    }

    public void Add(AnnotationItem item)
    {
        Checkpoint();
        _items.Add(item);
    }

    public void Remove(Guid id)
    {
        var existing = _items.FirstOrDefault(item => item.Id == id);
        if (existing is null) return;

        Checkpoint();
        _items.Remove(existing);
        if (SelectedId == id) SelectedId = null;
    }

    public AnnotationItem? Find(Guid id) => _items.FirstOrDefault(item => item.Id == id);

    /// <summary>Topmost item whose hit area contains the point.</summary>
    public AnnotationItem? HitTest(Point point) =>
        _items.AsEnumerable().Reverse().FirstOrDefault(item => item.HitBounds().Contains(point));

    /// <summary>Replaces an item in place, without a new checkpoint.</summary>
    public void Replace(AnnotationItem item)
    {
        var index = _items.FindIndex(existing => existing.Id == item.Id);
        if (index >= 0) _items[index] = item;
    }

    public void Clear()
    {
        if (_items.Count == 0) return;
        Checkpoint();
        _items.Clear();
        SelectedId = null;
    }

    public void Undo()
    {
        if (_undo.Count == 0) return;
        _redo.Push(_items.Select(item => item.Clone()).ToList());
        Restore(_undo.Pop());
    }

    public void Redo()
    {
        if (_redo.Count == 0) return;
        _undo.Push(_items.Select(item => item.Clone()).ToList());
        Restore(_redo.Pop());
    }

    private void Restore(List<AnnotationItem> state)
    {
        _items.Clear();
        _items.AddRange(state);
        if (SelectedId is not null && _items.All(item => item.Id != SelectedId)) SelectedId = null;
    }

    public JsonArray ToJson() => new(_items.Select(item => (JsonNode)item.ToJson()).ToArray());
}
