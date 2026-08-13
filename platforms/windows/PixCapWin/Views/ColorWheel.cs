using System;
using System.Drawing.Imaging;
using System.IO;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace PixCapWin.Views;

/// <summary>
/// An HSV colour wheel, drawn here rather than by WinUI.
///
/// WinUI's ColorPicker was the obvious choice and its spectrum renders as a
/// solid black square on this machine - explicit sizing, a Ring shape and
/// hosting outside a flyout all made no difference. The rest of that control
/// works, so the failure is in ColorSpectrum's own surface, and a machine
/// without a GPU is the likely reason: Direct3D already falls back to WARP
/// here.
///
/// The wheel below is a bitmap this class fills pixel by pixel and hands to an
/// Image. No composition surface, no effects, nothing to fall back from - if
/// the app draws anything at all, it draws this.
/// </summary>
public sealed class ColorWheel : StackPanel
{
    private const int Diameter = 220;

    private readonly Image _wheel = new() { Width = Diameter, Height = Diameter };
    private readonly Ellipse _marker;
    private readonly Canvas _overlay = new() { Width = Diameter, Height = Diameter };
    private readonly Slider _brightness;
    private readonly TextBox _hex;
    private readonly Border _preview;

    private double _hue;          // 0-360
    private double _saturation;   // 0-1
    private double _value = 1.0;  // 0-1
    private bool _updating;

    public event EventHandler<Color>? ColorChanged;

    public ColorWheel()
    {
        Spacing = 10;

        _marker = new Ellipse
        {
            Width = 14,
            Height = 14,
            Stroke = new SolidColorBrush(Colors.White),
            StrokeThickness = 2,
            IsHitTestVisible = false
        };

        _overlay.Children.Add(_marker);

        var stack = new Grid { Width = Diameter, Height = Diameter };
        stack.Children.Add(_wheel);
        stack.Children.Add(_overlay);
        stack.PointerPressed += OnWheelPointer;
        stack.PointerMoved += OnWheelPointer;

        _brightness = new Slider
        {
            Minimum = 0,
            Maximum = 100,
            Value = 100,
            Width = Diameter,
            Header = "Brightness"
        };
        _brightness.ValueChanged += (_, _) =>
        {
            if (_updating) return;
            _value = _brightness.Value / 100.0;
            Publish();
        };

        _preview = new Border
        {
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(90, 255, 255, 255))
        };

        _hex = new TextBox { Width = Diameter - 40, FontFamily = new FontFamily("Consolas") };
        _hex.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter) ApplyHexInput();
        };
        _hex.LostFocus += (_, _) => ApplyHexInput();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(_preview);
        row.Children.Add(_hex);

        Children.Add(stack);
        Children.Add(_brightness);
        Children.Add(row);

        _wheel.Source = RenderWheel();
    }

    /// <summary>Moves the wheel to a colour without raising ColorChanged.</summary>
    public void SetColor(Color color)
    {
        ToHsv(color, out _hue, out _saturation, out _value);

        _updating = true;
        _brightness.Value = _value * 100.0;
        _updating = false;

        Reflect();
    }

    private void ApplyHexInput()
    {
        var text = _hex.Text.Trim();
        if (text.Length == 0) return;

        var parsed = AnnotationCanvas.ParseColor(text);
        ToHsv(parsed, out _hue, out _saturation, out _value);

        _updating = true;
        _brightness.Value = _value * 100.0;
        _updating = false;

        Publish();
    }

    private void OnWheelPointer(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint((UIElement)sender);
        if (args.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse &&
            !point.Properties.IsLeftButtonPressed)
        {
            return;
        }

        var radius = Diameter / 2.0;
        var dx = point.Position.X - radius;
        var dy = point.Position.Y - radius;
        var distance = Math.Sqrt(dx * dx + dy * dy);

        // Outside the wheel still counts, clamped to the rim: a drag that
        // slips off the edge should saturate rather than stop responding.
        _saturation = Math.Min(1.0, distance / radius);
        _hue = (Math.Atan2(dy, dx) * 180.0 / Math.PI + 360.0) % 360.0;

        Publish();
    }

    private void Publish()
    {
        Reflect();
        ColorChanged?.Invoke(this, Current());
    }

    private Color Current() => FromHsv(_hue, _saturation, _value);

    private void Reflect()
    {
        var colour = Current();

        _preview.Background = new SolidColorBrush(colour);

        var text = $"#{colour.R:X2}{colour.G:X2}{colour.B:X2}";
        if (!string.Equals(_hex.Text, text, StringComparison.OrdinalIgnoreCase)) _hex.Text = text;

        var radius = Diameter / 2.0;
        var angle = _hue * Math.PI / 180.0;
        Canvas.SetLeft(_marker, radius + Math.Cos(angle) * _saturation * radius - _marker.Width / 2);
        Canvas.SetTop(_marker, radius + Math.Sin(angle) * _saturation * radius - _marker.Height / 2);
    }

    /// <summary>
    /// Paints the wheel once: hue around, saturation outward, at full value.
    /// Brightness is a separate slider, so the wheel itself never changes and
    /// is only built here.
    /// </summary>
    private static BitmapImage RenderWheel()
    {
        using var bitmap = new System.Drawing.Bitmap(Diameter, Diameter, PixelFormat.Format32bppArgb);
        var radius = Diameter / 2.0;

        for (var y = 0; y < Diameter; y++)
        {
            for (var x = 0; x < Diameter; x++)
            {
                var dx = x - radius + 0.5;
                var dy = y - radius + 0.5;
                var distance = Math.Sqrt(dx * dx + dy * dy);

                if (distance > radius)
                {
                    bitmap.SetPixel(x, y, System.Drawing.Color.Transparent);
                    continue;
                }

                var hue = (Math.Atan2(dy, dx) * 180.0 / Math.PI + 360.0) % 360.0;
                var colour = FromHsv(hue, Math.Min(1.0, distance / radius), 1.0);

                // Feather the last pixel of the rim so the circle is not jagged.
                var alpha = (byte)(255 * Math.Clamp(radius - distance, 0, 1));
                bitmap.SetPixel(x, y, System.Drawing.Color.FromArgb(alpha, colour.R, colour.G, colour.B));
            }
        }

        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        stream.Position = 0;

        var source = new BitmapImage();
        source.SetSource(stream.AsRandomAccessStream());
        return source;
    }

    private static Color FromHsv(double hue, double saturation, double value)
    {
        var chroma = value * saturation;
        var section = hue / 60.0;
        var second = chroma * (1 - Math.Abs(section % 2 - 1));
        var match = value - chroma;

        double r = 0, g = 0, b = 0;
        switch ((int)Math.Floor(section) % 6)
        {
            case 0: r = chroma; g = second; break;
            case 1: r = second; g = chroma; break;
            case 2: g = chroma; b = second; break;
            case 3: g = second; b = chroma; break;
            case 4: r = second; b = chroma; break;
            default: r = chroma; b = second; break;
        }

        return Color.FromArgb(
            255,
            (byte)Math.Round((r + match) * 255),
            (byte)Math.Round((g + match) * 255),
            (byte)Math.Round((b + match) * 255));
    }

    private static void ToHsv(Color colour, out double hue, out double saturation, out double value)
    {
        double r = colour.R / 255.0, g = colour.G / 255.0, b = colour.B / 255.0;

        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var delta = max - min;

        hue = 0;
        if (delta > 0)
        {
            if (max == r) hue = 60 * (((g - b) / delta + 6) % 6);
            else if (max == g) hue = 60 * ((b - r) / delta + 2);
            else hue = 60 * ((r - g) / delta + 4);
        }

        saturation = max <= 0 ? 0 : delta / max;
        value = max;
    }
}
