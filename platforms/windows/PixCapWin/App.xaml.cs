using System;
using System.Linq;
using Microsoft.UI.Xaml;

namespace PixCapWin;

public partial class App : Application
{
    /// <summary>Started by the login shortcut: go straight to the tray.</summary>
    private const string BackgroundSwitch = "--background";

    private Window? _window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var background = Environment.GetCommandLineArgs()
            .Any(argument => string.Equals(argument, BackgroundSwitch, StringComparison.OrdinalIgnoreCase));

        var window = new MainWindow();
        _window = window;

        // Activated either way, then hidden. A window that is never activated
        // has no XamlRoot, and the preview sizing asks it for the display
        // scale — so starting in the background would otherwise leave the
        // first render mis-sized.
        window.Activate();

        if (background) window.HideToTray(announce: false);
    }
}
