using System;
using System.Drawing;
using System.Windows.Forms;

namespace PixCapWin.Views;

/// <summary>
/// The notification-area icon that keeps PixCap alive.
///
/// The global shortcut only works while the process is running, so closing the
/// window hides it here instead of quitting. That makes the tray icon the only
/// visible sign the app exists, and the only way back to it — which is why
/// Quit is on its menu and not left to Task Manager.
///
/// Windows Forms again, for the same reason as the region overlay and the
/// hotkey sink: WinUI 3 has no notification-area API at all, and NotifyIcon is
/// a few lines. It runs on the UI thread, so WinUI's message loop drives it.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;

    public event EventHandler? OpenRequested;
    public event EventHandler? CaptureAreaRequested;
    public event EventHandler? QuitRequested;

    public TrayIcon(string shortcut)
    {
        var menu = new ContextMenuStrip();

        // ShortcutKeyDisplayString, not a tab in the text: a tab is drawn as
        // nothing at all here, which ran the two together as "Capture areaWin+Alt+S".
        var capture = new ToolStripMenuItem("Capture area") { ShortcutKeyDisplayString = shortcut };
        capture.Click += (_, _) => CaptureAreaRequested?.Invoke(this, EventArgs.Empty);

        var open = new ToolStripMenuItem("Open PixCap");
        open.Click += (_, _) => OpenRequested?.Invoke(this, EventArgs.Empty);

        var quit = new ToolStripMenuItem("Quit PixCap");
        quit.Click += (_, _) => QuitRequested?.Invoke(this, EventArgs.Empty);

        menu.Items.Add(capture);
        menu.Items.Add(open);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quit);

        _icon = new NotifyIcon
        {
            // Taken from the running executable rather than shipped separately,
            // so it cannot drift from the application icon.
            Icon = ExtractIcon(),
            Text = "PixCap",
            ContextMenuStrip = menu,
            Visible = true
        };

        _icon.DoubleClick += (_, _) => OpenRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Keeps the menu honest when the shortcut is rebound.</summary>
    public void UpdateShortcut(string shortcut)
    {
        if (_icon.ContextMenuStrip?.Items.Count > 0 &&
            _icon.ContextMenuStrip.Items[0] is ToolStripMenuItem capture)
        {
            capture.ShortcutKeyDisplayString = shortcut;
        }
    }

    /// <summary>Tells the user the app is still there after the window disappears.</summary>
    public void ShowHiddenNotice(string shortcut)
    {
        _icon.BalloonTipTitle = "PixCap is still running";
        _icon.BalloonTipText = $"{shortcut} captures an area. Quit from this icon's menu.";
        _icon.ShowBalloonTip(4000);
    }

    private static Icon ExtractIcon()
    {
        try
        {
            var path = Environment.ProcessPath;
            if (path is not null)
            {
                var icon = Icon.ExtractAssociatedIcon(path);
                if (icon is not null) return icon;
            }
        }
        catch
        {
            // Falls through to the stock icon below.
        }

        return SystemIcons.Application;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
