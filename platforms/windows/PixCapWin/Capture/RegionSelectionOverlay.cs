using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace PixCapWin.Capture;

/// <summary>Which display was drawn on, and the rectangle in its pixels.</summary>
public sealed record RegionSelection(DisplayCapture Display, int X, int Y, int Width, int Height);

/// <summary>
/// The region picker Windows does not provide.
///
/// GraphicsCapturePicker offers a window or a display and nothing smaller, so
/// this is the same idea as the macOS overlay
/// (platforms/macos/.../RegionSelectionOverlay.swift): a borderless
/// always-on-top surface over every display, a drag rectangle with a
/// dimensioned readout, and Escape to cancel.
///
/// It differs from macOS in one way, deliberately. macOS holds a live,
/// transparent overlay and excludes it from the capture. Here the displays are
/// captured first and the overlay shows that frozen image, so there is nothing
/// to exclude - and the pixels the user selects are the exact pixels they were
/// looking at, not whatever the screen shows a moment later.
///
/// It is Windows Forms rather than WinUI 3, which the rest of the app uses,
/// for one measured reason. WinUI routes pointer input through a content
/// island and applies ProtectedCursor only when a mouse message arrives, so an
/// overlay appearing under a pointer that is standing still keeps the arrow it
/// inherited from whatever was clicked; SetCursor from the app was observed to
/// change nothing, and synthetic moves were coalesced away. A classic HWND
/// owns WM_SETCURSOR, so the crosshair is correct from the moment it appears.
/// Working in physical pixels throughout also removes the DIP conversions the
/// selection maths needed.
/// </summary>
public static class RegionSelectionOverlay
{
    private const int MinimumSelection = 8;

    /// <summary>
    /// Puts an overlay on every captured display and completes when the user
    /// picks a region, presses Escape, or right-clicks to cancel.
    /// </summary>
    public static Task<RegionSelection?> PickAsync(IReadOnlyList<DisplayCapture> displays)
    {
        var completion = new TaskCompletionSource<RegionSelection?>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        // Its own STA thread with its own message loop. Showing a Form from the
        // WinUI thread would mean two frameworks pumping one queue; this keeps
        // them apart, and the overlay is modal by nature anyway.
        var thread = new Thread(() =>
        {
            try
            {
                var session = new OverlaySession(displays);
                Application.Run(session);
                completion.TrySetResult(session.Result);
            }
            catch (Exception error)
            {
                completion.TrySetException(error);
            }
        })
        {
            IsBackground = true
        };

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        return completion.Task;
    }

    /// <summary>Holds one overlay per display, and ends when any of them settles.</summary>
    private sealed class OverlaySession : ApplicationContext
    {
        private readonly List<OverlayForm> _forms = new();
        private bool _settled;

        public RegionSelection? Result { get; private set; }

        public OverlaySession(IReadOnlyList<DisplayCapture> displays)
        {
            foreach (var display in displays)
            {
                var form = new OverlayForm(display);
                form.Finished += OnFinished;
                _forms.Add(form);
            }

            foreach (var form in _forms)
            {
                form.Show();
            }

            _forms[0].Activate();
        }

        private void OnFinished(object? sender, RegionSelection? selection)
        {
            if (_settled) return;
            _settled = true;

            Result = selection;

            foreach (var form in _forms)
            {
                form.Finished -= OnFinished;
                form.Close();
            }

            ExitThread();
        }
    }

    /// <summary>One display's worth of frozen screenshot, dimmed, with a drag rectangle.</summary>
    private sealed class OverlayForm : Form
    {
        private static readonly Color DimColor = Color.FromArgb(110, 0, 0, 0);
        private static readonly Color EdgeColor = Color.FromArgb(255, 0, 120, 215);

        private readonly DisplayCapture _display;
        private readonly Bitmap _frame;

        private Point? _anchor;
        private Rectangle _selection;

        public event EventHandler<RegionSelection?>? Finished;

        public OverlayForm(DisplayCapture display)
        {
            _display = display;
            _frame = new Bitmap(new MemoryStream(display.Frame.PngBytes));

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            // No auto-scaling: the process is per-monitor DPI aware, so bounds
            // and mouse positions are physical pixels, the same units the
            // captured frame is in. Nothing needs converting.
            AutoScaleMode = AutoScaleMode.None;
            Bounds = new Rectangle(display.Left, display.Top, display.Width, display.Height);
            TopMost = true;
            ShowInTaskbar = false;
            DoubleBuffered = true;
            KeyPreview = true;
            BackColor = Color.Black;
            Cursor = Cursors.Cross;
        }

        /// <summary>Pixels in the captured frame per pixel on screen.</summary>
        private float FrameScale =>
            ClientSize.Width > 0 ? (float)_frame.Width / ClientSize.Width : 1f;

        protected override void OnPaint(PaintEventArgs e)
        {
            var canvas = e.Graphics;
            canvas.InterpolationMode = InterpolationMode.NearestNeighbor;
            canvas.PixelOffsetMode = PixelOffsetMode.Half;

            canvas.DrawImage(_frame, ClientRectangle,
                new Rectangle(0, 0, _frame.Width, _frame.Height), GraphicsUnit.Pixel);

            using (var dim = new SolidBrush(DimColor))
            {
                canvas.FillRectangle(dim, ClientRectangle);
            }

            if (_selection.Width < 1 || _selection.Height < 1)
            {
                DrawHint(canvas);
                return;
            }

            // Undim the selection by painting that part of the frame again.
            canvas.DrawImage(_frame, _selection, Scaled(_selection), GraphicsUnit.Pixel);

            using (var edge = new Pen(EdgeColor, 1.5f))
            {
                canvas.DrawRectangle(edge, _selection);
            }

            DrawReadout(canvas);
        }

        private Rectangle Scaled(Rectangle screen)
        {
            var scale = FrameScale;
            return new Rectangle(
                (int)Math.Round(screen.X * scale),
                (int)Math.Round(screen.Y * scale),
                (int)Math.Round(screen.Width * scale),
                (int)Math.Round(screen.Height * scale));
        }

        private void DrawHint(Graphics canvas)
        {
            const string hint = "Drag to select an area    .    Esc or right-click to cancel";

            using var font = new Font("Segoe UI", 11f);
            var size = canvas.MeasureString(hint, font);
            var at = new PointF((ClientSize.Width - size.Width) / 2f, 40f);

            using var backing = new SolidBrush(Color.FromArgb(200, 0, 0, 0));
            canvas.FillRectangle(backing, at.X - 12, at.Y - 6, size.Width + 24, size.Height + 12);

            using var ink = new SolidBrush(Color.FromArgb(235, 255, 255, 255));
            canvas.DrawString(hint, font, ink, at);
        }

        private void DrawReadout(Graphics canvas)
        {
            var source = Scaled(_selection);
            var text = $"{source.Width} x {source.Height} px";

            using var font = new Font("Consolas", 9f);
            var size = canvas.MeasureString(text, font);

            // Above the selection when there is room, otherwise just inside it.
            var top = _selection.Top - size.Height - 8;
            if (top < 0) top = _selection.Top + 6;

            using var backing = new SolidBrush(Color.FromArgb(210, 0, 0, 0));
            canvas.FillRectangle(backing, _selection.Left, top, size.Width + 16, size.Height + 6);

            using var ink = new SolidBrush(Color.White);
            canvas.DrawString(text, font, ink, _selection.Left + 8, top + 3);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right)
            {
                Finished?.Invoke(this, null);
                return;
            }

            if (e.Button != MouseButtons.Left) return;

            _anchor = e.Location;
            _selection = Rectangle.Empty;
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_anchor is not { } anchor) return;

            var previous = _selection;
            _selection = Rectangle.FromLTRB(
                Math.Min(anchor.X, e.X),
                Math.Min(anchor.Y, e.Y),
                Math.Max(anchor.X, e.X),
                Math.Max(anchor.Y, e.Y));

            // Only the area the rectangle moved through needs repainting; the
            // frame underneath is large and redrawing all of it per mouse move
            // makes the drag stutter. The margin covers the border and readout.
            var dirty = Rectangle.Union(previous, _selection);
            dirty.Inflate(60, 60);
            Invalidate(dirty);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left || _anchor is null) return;

            var selection = _selection;
            _anchor = null;

            if (selection.Width < MinimumSelection || selection.Height < MinimumSelection)
            {
                Finished?.Invoke(this, null);
                return;
            }

            var source = Scaled(selection);
            Finished?.Invoke(this, new RegionSelection(
                _display, source.X, source.Y, source.Width, source.Height));
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode != Keys.Escape) return;
            e.Handled = true;
            Finished?.Invoke(this, null);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _frame.Dispose();
            base.Dispose(disposing);
        }
    }
}
