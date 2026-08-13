using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Input;
using PixCapWin.Capture;
using PixCapWin.Core;
using PixCapWin.Views;
using Windows.System;

namespace PixCapWin;

/// <summary>
/// Windows shell for PixCap.
///
/// Capture is platform-native (Windows.Graphics.Capture). File naming, the
/// history database, background presets, and syntax highlighting all come from
/// the same Rust core the macOS app links, so those cannot drift between
/// platforms.
///
/// Beautification and annotation are macOS-only: that renderer is written in
/// Swift, so there is nothing here to call. The Settings page says so rather
/// than leaving the absence to be discovered.
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly PixCapCore _core = new();
    private readonly ScreenCaptureEngine _capture = new();
    private readonly string _saveDirectory;
    private readonly AppSettings _settings;
    private readonly HotkeyListener _hotkeys = new();
    private TrayIcon? _tray;

    /// <summary>Set only by Quit, so closing the window hides it instead.</summary>
    private bool _quitting;

    /// <summary>The "still running" balloon is worth showing once, not every time.</summary>
    private bool _announcedTray;

    /// <summary>Set while the Settings page is listening for a new shortcut.</summary>
    private bool _listeningForHotkey;

    /// <summary>Guards against a second capture starting on top of one in flight.</summary>
    private bool _capturing;

    private List<CaptureItem> _items = [];
    private int _counter;

    private readonly BeautifyOptions _beautify = new();
    private readonly AnnotationStore _annotations = new();
    private AnnotationCanvas? _annotationCanvas;
    private AnnotationItem? _pendingText;
    private CaptureItem? _editTarget;
    private string? _renderedPath;
    /// <summary>Coalesces slider drags into one render.</summary>
    private CancellationTokenSource? _renderDebounce;

    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        _saveDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "PixCap");
        Directory.CreateDirectory(_saveDirectory);

        var appData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixCap");
        Directory.CreateDirectory(appData);
        _core.OpenHistory(Path.Combine(appData, "history.sqlite"));

        _settings = AppSettings.Load(Path.Combine(appData, "settings.json"));

        SaveLocationText.Text = _saveDirectory;
        PatternBox.Text = _core.DefaultNamingPattern;

        SetUpTray();
        SetUpHotkey();
        LoadCoreInfo();
        LoadBeautifyControls();
        BuildToolPalette();
        BuildAnnotationCanvas();
        // After the canvas: the swatches set its colour, and it has to exist.
        BuildColorSwatches();
        LoadHistory();
    }

    // MARK: - Navigation

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? "capture";

        CapturePage.Visibility = tag == "capture" ? Visibility.Visible : Visibility.Collapsed;
        BeautifyPage.Visibility = tag == "beautify" ? Visibility.Visible : Visibility.Collapsed;
        LibraryPage.Visibility = tag == "library" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;

        if (tag == "library") LoadHistory(SearchBox.Text);
        if (tag == "beautify") UpdateBeautifyTarget();
    }

    // MARK: - Capture

    private async void OnCaptureClick(object sender, RoutedEventArgs e)
    {
        try
        {
            CaptureButton.IsEnabled = false;
            StatusText.Text = "Choose a window or display...";

            var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
            var result = await _capture.CaptureWithPickerAsync(handle);

            if (result is null)
            {
                StatusText.Text = "Capture cancelled";
                return;
            }

            await StoreCaptureAsync(result, "window");
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Capture failed: {ex.Message}";
        }
        finally
        {
            CaptureButton.IsEnabled = true;
        }
    }

    /// <summary>
    /// Captures every display, then lets the user drag out a region of the
    /// frozen image.
    ///
    /// The main window is hidden first. Windows has no way to keep an
    /// application out of a display capture that is already in flight, and a
    /// PixCap window frozen into the middle of the shot is never what was
    /// wanted.
    /// </summary>
    private async void OnCaptureAreaClick(object sender, RoutedEventArgs e) =>
        await CaptureAreaAsync(fromHotkey: false);

    private async Task CaptureAreaAsync(bool fromHotkey)
    {
        // The shortcut can arrive while a capture is already on screen, or
        // while the last one is still being written out.
        if (_capturing) return;
        _capturing = true;

        RegionSelection? selection = null;

        try
        {
            CaptureAreaButton.IsEnabled = false;
            CaptureButton.IsEnabled = false;
            StatusText.Text = "Drag to select an area...";

            AppWindow.Hide();
            // One frame is not enough: the window is gone from the compositor
            // only after it has been through a present.
            await Task.Delay(220);

            var displays = await _capture.CaptureDisplaysAsync();
            selection = await RegionSelectionOverlay.PickAsync(displays);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Capture failed: {ex.Message}";
        }
        finally
        {
            AppWindow.Show();
            CaptureAreaButton.IsEnabled = true;
            CaptureButton.IsEnabled = true;
        }

        if (selection is null)
        {
            if (!StatusText.Text.StartsWith("Capture failed")) StatusText.Text = "Capture cancelled";
            _capturing = false;
            return;
        }

        try
        {
            var cropped = await ScreenCaptureEngine.CropAsync(
                selection.Display.Frame, selection.X, selection.Y, selection.Width, selection.Height);

            await StoreCaptureAsync(cropped, "region");

            // Started from elsewhere, so PixCap is behind whatever the user was
            // actually looking at. Bring it forward: the capture is only half
            // the job, and the other half is here.
            if (fromHotkey) Activate();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Capture failed: {ex.Message}";
        }
        finally
        {
            _capturing = false;
        }
    }

    // MARK: - Global shortcut

    /// <summary>
    /// Puts PixCap in the notification area and keeps it there.
    ///
    /// The shortcut only works while the process is running, so the window's
    /// close button hides rather than quits. Without an icon by the clock that
    /// would be indistinguishable from a leak — a process the user cannot see,
    /// cannot reach, and did not agree to.
    /// </summary>
    private void SetUpTray()
    {
        _tray = new TrayIcon(_settings.EffectiveHotkey.ToString());
        _tray.OpenRequested += (_, _) => ShowFromTray();
        _tray.CaptureAreaRequested += async (_, _) => await CaptureAreaAsync(fromHotkey: true);
        _tray.QuitRequested += (_, _) => Quit();

        AppWindow.Closing += (_, args) =>
        {
            if (_quitting) return;
            args.Cancel = true;
            HideToTray(announce: true);
        };
    }

    /// <summary>Hides the window, leaving the app running for the shortcut.</summary>
    public void HideToTray(bool announce)
    {
        AppWindow.Hide();

        if (!announce || _announcedTray) return;
        _announcedTray = true;
        _tray?.ShowHiddenNotice(_settings.EffectiveHotkey.ToString());
    }

    private void ShowFromTray()
    {
        AppWindow.Show();
        Activate();
    }

    private void Quit()
    {
        _quitting = true;
        _tray?.Dispose();
        _hotkeys.Dispose();
        Application.Current.Exit();
    }

    private void SetUpHotkey()
    {
        _hotkeys.Pressed += async (_, _) => await CaptureAreaAsync(fromHotkey: true);
        Closed += (_, _) =>
        {
            _hotkeys.Dispose();
            _tray?.Dispose();
        };

        // Key events reach the window before anything claims them, so a
        // shortcut containing Alt is not swallowed as a menu accelerator.
        if (Content is UIElement root)
        {
            root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnRootKeyDown), true);
        }

        ApplyHotkey(_settings.EffectiveHotkey, remember: false);
    }

    private void ApplyHotkey(HotkeyBinding binding, bool remember)
    {
        var claimed = _hotkeys.Register(binding);

        HotkeyText.Text = binding.ToString();
        _tray?.UpdateShortcut(binding.ToString());
        HotkeyStatus.Text = claimed
            ? $"{binding} starts an area capture from any application."
            : $"Windows would not give PixCap {binding} - another application already owns it. Choose a different combination.";

        if (!remember) return;

        _settings.CaptureAreaHotkey = binding;
        _settings.Save();
    }

    private void OnHotkeyChangeClick(object sender, RoutedEventArgs e)
    {
        _listeningForHotkey = true;
        HotkeyChangeButton.Content = "Press keys";
        HotkeyStatus.Text = "Hold the modifiers and press a key. Escape keeps the current shortcut.";

        // The handler is on the window root, but something has to hold focus
        // for a key press to get there at all.
        HotkeyChangeButton.Focus(FocusState.Programmatic);
    }

    private void OnHotkeyResetClick(object sender, RoutedEventArgs e)
    {
        StopListeningForHotkey();
        ApplyHotkey(HotkeyBinding.Default, remember: true);
    }

    private void OnRootKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_listeningForHotkey) return;

        // A modifier on its own is the user still assembling the combination.
        if (e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu
            or VirtualKey.LeftWindows or VirtualKey.RightWindows)
        {
            return;
        }

        e.Handled = true;

        if (e.Key == VirtualKey.Escape)
        {
            StopListeningForHotkey();
            HotkeyStatus.Text = $"Kept {_settings.EffectiveHotkey}.";
            return;
        }

        var modifiers = 0u;
        if (IsHeld(VirtualKey.Control)) modifiers |= HotkeyBinding.Control;
        if (IsHeld(VirtualKey.Shift)) modifiers |= HotkeyBinding.Shift;
        if (IsHeld(VirtualKey.Menu)) modifiers |= HotkeyBinding.Alt;
        if (IsHeld(VirtualKey.LeftWindows) || IsHeld(VirtualKey.RightWindows))
        {
            modifiers |= HotkeyBinding.Windows;
        }

        if (modifiers == 0)
        {
            HotkeyStatus.Text = "A global shortcut needs at least one of Win, Ctrl, Alt or Shift.";
            return;
        }

        StopListeningForHotkey();
        ApplyHotkey(new HotkeyBinding(modifiers, (uint)e.Key), remember: true);
    }

    private void StopListeningForHotkey()
    {
        _listeningForHotkey = false;
        HotkeyChangeButton.Content = "Change";
    }

    /// <summary>
    /// Whether a modifier is down right now.
    ///
    /// Read from the keyboard state rather than from the key event: the Windows
    /// key is handled by the shell and never arrives as a modifier on the
    /// event itself.
    /// </summary>
    private static bool IsHeld(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// <summary>Names, saves, and indexes a capture, then refreshes the UI.</summary>
    private async Task StoreCaptureAsync(CaptureResult result, string mode)
    {
        var name = _core.ResolveFilename(
            PatternBox.Text, mode, null, result.Title,
            result.Width, result.Height, ++_counter);

        var path = await result.SaveAsync(_saveDirectory, Sanitize(name));

        _core.InsertHistory(new ScreenshotRecord
        {
            Filepath = path,
            CapturedAt = DateTime.UtcNow.ToString("o"),
            CaptureMode = mode,
            Width = result.Width,
            Height = result.Height
        });

        StatusText.Text = $"Saved {Path.GetFileName(path)}  ({result.Width} x {result.Height})";
        LoadHistory();
        ShowLatest();
    }

    private void OnOpenFolderClick(object sender, RoutedEventArgs e)
    {
        Process.Start(new ProcessStartInfo { FileName = _saveDirectory, UseShellExecute = true });
    }

    // MARK: - Library

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        LoadHistory(sender.Text);
    }

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not CaptureItem item) return;

        if (!item.FileExists)
        {
            StatusText.Text = "That file is no longer on disk.";
            return;
        }

        Process.Start(new ProcessStartInfo { FileName = item.FilePath, UseShellExecute = true });
    }

    private void LoadHistory(string query = "")
    {
        var records = string.IsNullOrWhiteSpace(query)
            ? _core.RecentHistory()
            : _core.SearchHistory(query);

        _items = records.Select(record => new CaptureItem(record)).ToList();
        HistoryGrid.ItemsSource = _items;

        var empty = _items.Count == 0;
        EmptyLibraryPanel.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        HistoryGrid.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;

        EmptyLibraryText.Text = string.IsNullOrWhiteSpace(query)
            ? "Nothing captured yet"
            : $"No captures match \"{query}\"";

        LibrarySummary.Text = _items.Count == 1
            ? "1 capture"
            : $"{_items.Count} captures";

        ShowLatest();

        if (BeautifyPage.Visibility == Visibility.Visible) UpdateBeautifyTarget();
    }

    /// <summary>Puts the newest capture on the Capture page.</summary>
    private void ShowLatest()
    {
        var latest = _items.FirstOrDefault(item => item.FileExists);

        if (latest is null)
        {
            NoCapturesPanel.Visibility = Visibility.Visible;
            LatestPanel.Visibility = Visibility.Collapsed;
            return;
        }

        NoCapturesPanel.Visibility = Visibility.Collapsed;
        LatestPanel.Visibility = Visibility.Visible;
        LatestTitle.Text = latest.Title;
        LatestSubtitle.Text = latest.Subtitle;

        try
        {
            LatestImage.Source = new BitmapImage(new Uri(latest.FilePath));
        }
        catch
        {
            LatestImage.Source = null;
        }
    }

    // MARK: - Beautify

    private void LoadBeautifyControls()
    {
        var presets = _core.BackgroundPresets;
        PresetCombo.ItemsSource = presets.Select(preset => preset.Name).ToList();

        var index = presets.ToList().FindIndex(preset => preset.Id == _beautify.BackgroundPreset);
        PresetCombo.SelectedIndex = index >= 0 ? index : 0;

        FrameCombo.SelectedIndex = 0;
        TextureCombo.SelectedIndex = 0;
    }

    /// <summary>
    /// Points the Beautify page at the newest capture, and renders it.
    ///
    /// Rendering here is the point. The page holds no preview of its own, so
    /// pointing it at a capture without asking for one left the panel empty
    /// until some unrelated setting was nudged — and if an earlier capture had
    /// been rendered, left the *previous* capture on screen under the new
    /// one's name.
    /// </summary>
    private async void UpdateBeautifyTarget()
    {
        var source = _items.FirstOrDefault(item => item.FileExists);
        var changed = source?.FilePath != _editTarget?.FilePath;
        _editTarget = source;

        BeautifyEmptyPanel.Visibility = source is null ? Visibility.Visible : Visibility.Collapsed;
        RenderButton.IsEnabled = source is not null;

        BeautifySubtitle.Text = source is null
            ? "Rendered by the shared Rust core."
            : $"Source: {source.Title}";

        if (source is null)
        {
            BeautifyPreview.Source = null;
            BeautifyPreview.Visibility = Visibility.Collapsed;
            CanvasSizeText.Text = string.Empty;
            return;
        }

        if (changed)
        {
            // Annotations and the crop were positioned against the capture that
            // is being replaced; carrying them over would put them at
            // meaningless coordinates on this one.
            _annotations.Clear();
            _beautify.Crop = null;
            ResetCropButton.IsEnabled = false;
            UpdateHistoryButtons();

            // Better a blank panel for the length of one render than the wrong
            // screenshot, which is what this looked like from the outside.
            BeautifyPreview.Source = null;
            BeautifyPreview.Visibility = Visibility.Collapsed;
        }

        UpdateCanvasSize(source);

        if (changed || BeautifyPreview.Source is null)
        {
            await RenderAsync();
        }
    }

    private void UpdateCanvasSize(CaptureItem? source)
    {
        if (source?.Record.Width is not > 0 || source.Record.Height is not > 0)
        {
            CanvasSizeText.Text = string.Empty;
            return;
        }

        ReadOptionsFromControls();

        var size = _core.CanvasSize(
            source.FilePath, _beautify,
            (int)source.Record.Width!.Value, (int)source.Record.Height!.Value);

        CanvasSizeText.Text = size is null
            ? string.Empty
            : $"Canvas {size.Value.Width:0} x {size.Value.Height:0} points, exported at 2x.";
    }

    private void ReadOptionsFromControls()
    {
        var presets = _core.BackgroundPresets;
        if (PresetCombo.SelectedIndex >= 0 && PresetCombo.SelectedIndex < presets.Count)
        {
            _beautify.BackgroundPreset = presets[PresetCombo.SelectedIndex].Id;
        }

        _beautify.FrameStyle = FrameCombo.SelectedItem as string ?? "macOS";
        _beautify.Texture = TextureCombo.SelectedItem as string ?? "None";
        _beautify.Padding = PaddingSlider.Value;
        _beautify.CornerRadius = RadiusSlider.Value;
        _beautify.ShadowBlur = ShadowSlider.Value;
        _beautify.NoiseIntensity = GrainSlider.Value / 100.0;
        _beautify.FrameTitle = string.IsNullOrWhiteSpace(TitleBox.Text) ? null : TitleBox.Text;
    }

    private void OnOptionChanged(object sender, SelectionChangedEventArgs e) => ScheduleRender();

    private void OnSliderChanged(object sender, RangeBaseValueChangedEventArgs e) => ScheduleRender();

    private void OnTitleChanged(object sender, TextChangedEventArgs e) => ScheduleRender();

    /// <summary>
    /// Re-renders shortly after the controls stop moving. Rendering on every
    /// slider tick would queue dozens of full-resolution renders.
    /// </summary>
    private async void ScheduleRender()
    {
        if (BeautifyPage.Visibility != Visibility.Visible) return;

        UpdateCanvasSize(_items.FirstOrDefault(item => item.FileExists));

        _renderDebounce?.Cancel();
        var cancellation = new CancellationTokenSource();
        _renderDebounce = cancellation;

        try
        {
            await Task.Delay(250, cancellation.Token);
            await RenderAsync();
        }
        catch (TaskCanceledException)
        {
            // Superseded by a newer change.
        }
    }

    private async void OnRenderClick(object sender, RoutedEventArgs e) => await RenderAsync();

    /// <summary>Pixels per canvas point for an export. Retina quality.</summary>
    private const float ExportScale = 2.0f;

    /// <summary>
    /// Pixels per canvas point for the preview: exactly what the screen will
    /// show, and no more.
    ///
    /// Rendering at export scale and shrinking the result to fit meant paying
    /// for four to sixteen times the pixels the user ever saw, and the shadow
    /// blur — the most expensive thing the renderer does — scales with the
    /// blur radius in pixels as well. On a 4K capture that was the difference
    /// between a preview and a coffee break.
    /// </summary>
    private float PreviewScale(CaptureItem source)
    {
        if (source.Record.Width is not > 0 || source.Record.Height is not > 0) return ExportScale;

        var size = _core.CanvasSize(
            source.FilePath, _beautify,
            (int)source.Record.Width!.Value, (int)source.Record.Height!.Value);

        if (size is not { Width: > 0, Height: > 0 }) return ExportScale;

        // Measure the container, not PreviewHost: PreviewHost is centred, so it
        // is exactly as big as the preview already inside it, and asking it how
        // much room there is answers with the last render's size. Force a
        // layout pass first, because the first render after the page becomes
        // visible would otherwise measure a page that has never been arranged
        // and fall all the way to the minimum scale.
        PreviewArea.UpdateLayout();

        var available = PreviewArea.ActualWidth;
        var availableHeight = PreviewArea.ActualHeight;

        if (available <= 0 || availableHeight <= 0) return ExportScale;

        var fit = Math.Min(available / size.Value.Width, availableHeight / size.Value.Height);

        // A DIP is not a pixel on a scaled display, so the render is sized in
        // device pixels; below a quarter scale the preview stops representing
        // the export.
        return (float)Math.Clamp(fit * RasterizationScale, 0.25, ExportScale);
    }

    /// <summary>Device pixels per DIP for the window this preview is in.</summary>
    private double RasterizationScale
    {
        get
        {
            var scale = BeautifyPreview.XamlRoot?.RasterizationScale ?? 1.0;
            return scale > 0 ? scale : 1.0;
        }
    }

    private async Task RenderAsync()
    {
        // The same capture the overlay is mapped to. Deriving the source
        // separately here let the preview and the annotation geometry drift
        // apart the moment a new capture arrived.
        var source = _editTarget ?? _items.FirstOrDefault(item => item.FileExists);
        if (source is null) return;

        _editTarget = source;
        ReadOptionsFromControls();

        BeautifyProgress.IsActive = true;
        RenderButton.IsEnabled = false;

        // Previews render to a temporary file; "Save as" renders again at
        // export scale.
        var output = Path.Combine(Path.GetTempPath(), $"pixcap-preview-{Guid.NewGuid():N}.png");
        var sourcePath = source.FilePath;
        var scale = PreviewScale(source);

        // From here until the new preview is on screen, the preview underneath
        // the overlay is a render behind, so the overlay draws the committed
        // annotations itself rather than letting them disappear.
        if (_annotationCanvas is not null) _annotationCanvas.PreviewIsStale = true;

        var clock = Stopwatch.StartNew();

        try
        {
            var layer = _annotations.Items.Select(item => item.Clone()).ToList();
            var rendered = await Task.Run(
                () => _core.RenderDocument(sourcePath, _beautify, scale, output, layer));

            Debug.WriteLine($"[pixcap] render at {scale:0.00}x took {clock.ElapsedMilliseconds} ms");

            if (!rendered)
            {
                StatusText.Text = "The renderer could not produce an image.";
                return;
            }

            // Load through a stream so the file is not locked, otherwise the
            // next preview cannot replace it.
            var bitmap = new BitmapImage();
            using (var stream = File.OpenRead(output))
            {
                await bitmap.SetSourceAsync(stream.AsRandomAccessStream());
            }

            BeautifyPreview.Source = bitmap;
            BeautifyPreview.Visibility = Visibility.Visible;
            BeautifyEmptyPanel.Visibility = Visibility.Collapsed;

            // One image pixel per device pixel, which is what it was rendered
            // for. The overlay is then matched to it so the two share one
            // coordinate space.
            var displayWidth = bitmap.PixelWidth / RasterizationScale;
            var displayHeight = bitmap.PixelHeight / RasterizationScale;

            BeautifyPreview.Width = displayWidth;
            BeautifyPreview.Height = displayHeight;

            // The preview now holds the committed annotations, so the overlay
            // can hand them back. SyncCanvasGeometry redraws either way.
            if (_annotationCanvas is not null) _annotationCanvas.PreviewIsStale = false;

            SyncCanvasGeometry(displayWidth, displayHeight);

            DeletePreviousPreview();
            _renderedPath = output;

            SaveRenderButton.IsEnabled = true;
            RevealRenderButton.IsEnabled = true;
            var took = $"{clock.ElapsedMilliseconds} ms";
            StatusText.Text = _annotations.IsEmpty
                ? $"Rendered {Path.GetFileName(sourcePath)} in {took}"
                : $"Rendered {Path.GetFileName(sourcePath)} with {_annotations.Items.Count} annotations in {took}";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Render failed: {ex.Message}";
        }
        finally
        {
            BeautifyProgress.IsActive = false;
            RenderButton.IsEnabled = true;
        }
    }

    private void DeletePreviousPreview()
    {
        if (_renderedPath is null || !File.Exists(_renderedPath)) return;
        try { File.Delete(_renderedPath); } catch { /* held by the viewer; harmless */ }
    }

    private async void OnSaveRenderClick(object sender, RoutedEventArgs e)
    {
        if (_renderedPath is null || !File.Exists(_renderedPath)) return;

        var source = _items.FirstOrDefault(item => item.FileExists);
        if (source is null) return;

        var picker = new Windows.Storage.Pickers.FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(
            picker, WinRT.Interop.WindowNative.GetWindowHandle(this));

        picker.SuggestedFileName = "PixCap-beautified";
        picker.FileTypeChoices.Add("PNG image", new List<string> { ".png" });

        var file = await picker.PickSaveFileAsync();
        if (file is null) return;

        // The preview is only as large as the screen needed it to be, so an
        // export is a fresh render at full scale rather than a copy of it.
        ReadOptionsFromControls();
        var sourcePath = source.FilePath;
        var destination = file.Path;
        var layer = _annotations.Items.Select(item => item.Clone()).ToList();

        BeautifyProgress.IsActive = true;
        StatusText.Text = $"Rendering {file.Name} at {ExportScale:0}x...";

        try
        {
            var saved = await Task.Run(
                () => _core.RenderDocument(sourcePath, _beautify, ExportScale, destination, layer));

            StatusText.Text = saved
                ? $"Saved {file.Name}"
                : $"Could not render {file.Name}";
        }
        finally
        {
            BeautifyProgress.IsActive = false;
        }
    }

    private void OnRevealRenderClick(object sender, RoutedEventArgs e)
    {
        if (_renderedPath is null || !File.Exists(_renderedPath)) return;
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{_renderedPath}\""
        });
    }

    // MARK: - Annotation editor

    /// <summary>
    /// Quick swatches. Not the whole choice — the button beside them opens a
    /// full picker — but the colours reached for most often, one click away.
    /// </summary>
    private static readonly (string Name, string Hex)[] AnnotationColors =
    [
        ("Red", "#FF3366"), ("Cyan", "#00E5FF"), ("Amber", "#FFB300"),
        ("Green", "#27C93F"), ("White", "#FFFFFF"), ("Black", "#101010")
    ];

    private void BuildColorSwatches()
    {
        _colorWheel = new ColorWheel();
        _colorWheel.ColorChanged += (_, colour) =>
        {
            if (_syncingColor) return;
            ApplyAnnotationColor($"#{colour.R:X2}{colour.G:X2}{colour.B:X2}");
        };
        ColorFlyout.Content = _colorWheel;

        var swatches = new List<Button>();

        foreach (var (name, hex) in AnnotationColors)
        {
            var button = new Button
            {
                Width = 26,
                Height = 26,
                Padding = new Thickness(0),
                Tag = hex,
                Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                    AnnotationCanvas.ParseColor(hex))
            };

            ToolTipService.SetToolTip(button, name);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
            button.Click += (sender, _) =>
            {
                if (sender is Button { Tag: string picked }) ApplyAnnotationColor(picked);
            };

            swatches.Add(button);
        }

        ColorSwatches.ItemsSource = swatches;
        ApplyAnnotationColor(_settings.AnnotationColorHex);
    }

    /// <summary>Stops the wheel and the swatches from answering each other.</summary>
    private bool _syncingColor;

    private ColorWheel? _colorWheel;

    /// <summary>
    /// Sets the colour for what gets drawn next — and for the current
    /// selection, if there is one.
    ///
    /// Recolouring the selection is the reason this control exists: choosing a
    /// colour that only applied to the next shape would mean deleting and
    /// redrawing anything already on the canvas.
    /// </summary>
    private void ApplyAnnotationColor(string hex)
    {
        if (_annotationCanvas is null) return;

        _annotationCanvas.ColorHex = hex;

        var colour = AnnotationCanvas.ParseColor(hex);

        ColorHexText.Text = hex.ToUpperInvariant();
        ColorPreview.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(colour);

        // So the wheel opens showing where you already are, whichever control
        // set it.
        _syncingColor = true;
        _colorWheel?.SetColor(colour);
        _syncingColor = false;

        _settings.AnnotationColorHex = hex;
        _settings.Save();

        if (_annotations.SelectedId is not { } id || _annotations.Find(id) is not { } selected) return;
        if (string.Equals(selected.ColorHex, hex, StringComparison.OrdinalIgnoreCase)) return;

        _annotations.Checkpoint();
        var recoloured = selected.Clone();
        recoloured.ColorHex = hex;
        _annotations.Replace(recoloured);
        _annotations.SelectedId = id;

        UpdateHistoryButtons();
        _ = RenderAsync();
    }

    private void BuildToolPalette()
    {
        var tools = Enum.GetValues<AnnotationTool>();
        var buttons = new List<Button>();

        foreach (var tool in tools)
        {
            var button = new Button
            {
                // The icon is the button; the label survives as the tooltip and
                // as the accessible name, so the tool is still identifiable
                // without recognising the glyph.
                Content = new FontIcon { Glyph = tool.Glyph(), FontSize = 16 },
                Tag = tool,
                Width = 40,
                Height = 36,
                Padding = new Thickness(0)
            };

            ToolTipService.SetToolTip(button, tool.Label());
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tool.Label());

            button.Click += OnToolClick;
            buttons.Add(button);
        }

        ToolPalette.ItemsSource = buttons;
        HighlightSelectedTool();
    }

    private void OnToolClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: AnnotationTool tool }) return;

        if (_annotationCanvas is not null)
        {
            _annotationCanvas.Tool = tool;
            if (tool != AnnotationTool.Select)
            {
                _annotations.SelectedId = null;
                _annotationCanvas.Redraw();
            }
        }

        HighlightSelectedTool();
        StatusText.Text = tool == AnnotationTool.Select
            ? "Select: click an annotation, drag to move"
            : $"{tool.Label()} tool";
    }

    private void HighlightSelectedTool()
    {
        if (ToolPalette.ItemsSource is not List<Button> buttons) return;

        foreach (var button in buttons)
        {
            var isActive = _annotationCanvas is not null &&
                           button.Tag is AnnotationTool tool && tool == _annotationCanvas.Tool;

            button.Style = isActive
                ? (Style)Application.Current.Resources["AccentButtonStyle"]
                : null;
        }
    }

    private void BuildAnnotationCanvas()
    {
        _annotationCanvas = new AnnotationCanvas(_annotations);
        _annotationCanvas.LayerChanged += async (_, _) =>
        {
            UpdateHistoryButtons();
            await RenderAsync();
        };
        _annotationCanvas.TextRequested += OnTextRequested;
        _annotationCanvas.CropRequested += OnCropRequested;

        CanvasHost.Child = _annotationCanvas;
    }

    private void OnTextRequested(object? sender, AnnotationItem item)
    {
        _pendingText = item;
        TextEntryBox.Text = string.Empty;
        TextEntryBox.Visibility = Visibility.Visible;
        TextEntryBox.Focus(FocusState.Programmatic);
    }

    private async void OnTextEntryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            _pendingText = null;
            TextEntryBox.Visibility = Visibility.Collapsed;
            return;
        }

        if (e.Key != Windows.System.VirtualKey.Enter) return;

        if (_pendingText is { } item && !string.IsNullOrWhiteSpace(TextEntryBox.Text))
        {
            item.Text = TextEntryBox.Text;
            _annotations.Add(item);
            UpdateHistoryButtons();
            await RenderAsync();
        }

        _pendingText = null;
        TextEntryBox.Visibility = Visibility.Collapsed;
    }

    private async void OnCropRequested(object? sender, Windows.Foundation.Rect rect)
    {
        _beautify.Crop = [rect.X, rect.Y, rect.Width, rect.Height];
        ResetCropButton.IsEnabled = true;
        StatusText.Text = $"Cropped to {rect.Width:0} x {rect.Height:0}. Reset from the sidebar.";
        await RenderAsync();
    }

    private void OnAnnotationOptionChanged(object sender, SelectionChangedEventArgs e) =>
        ApplyAnnotationOptions();

    private void OnAnnotationSliderChanged(object sender, RangeBaseValueChangedEventArgs e) =>
        ApplyAnnotationOptions();

    private void OnAnnotationCheckChanged(object sender, RoutedEventArgs e) =>
        ApplyAnnotationOptions();

    private void ApplyAnnotationOptions()
    {
        if (_annotationCanvas is null) return;

        _annotationCanvas.StrokeWidth = StrokeSlider.Value;
        _annotationCanvas.Filled = FilledCheck.IsChecked == true;
        _annotationCanvas.Dashed = DashedCheck.IsChecked == true;
    }

    private async void OnUndoClick(object sender, RoutedEventArgs e)
    {
        _annotations.Undo();
        UpdateHistoryButtons();
        await RenderAsync();
    }

    private async void OnRedoClick(object sender, RoutedEventArgs e)
    {
        _annotations.Redo();
        UpdateHistoryButtons();
        await RenderAsync();
    }

    private async void OnClearClick(object sender, RoutedEventArgs e)
    {
        _annotations.Clear();
        UpdateHistoryButtons();
        await RenderAsync();
    }

    private async void OnResetCropClick(object sender, RoutedEventArgs e)
    {
        _beautify.Crop = null;
        ResetCropButton.IsEnabled = false;
        StatusText.Text = "Crop reset";
        await RenderAsync();
    }

    private void UpdateHistoryButtons()
    {
        UndoButton.IsEnabled = _annotations.CanUndo;
        RedoButton.IsEnabled = _annotations.CanRedo;
        ClearButton.IsEnabled = !_annotations.IsEmpty;
        _annotationCanvas?.Redraw();
    }

    /// <summary>
    /// Sizes the overlay to the rendered preview and gives it the renderer's
    /// layout, so pointer positions convert into image space correctly.
    /// </summary>
    private void SyncCanvasGeometry(double previewWidth, double previewHeight)
    {
        if (_annotationCanvas is null || _editTarget is null) return;
        if (_editTarget.Record.Width is not > 0 || _editTarget.Record.Height is not > 0) return;

        var layout = _core.Layout(
            _editTarget.FilePath, _beautify, _annotations.Items,
            (int)_editTarget.Record.Width!.Value, (int)_editTarget.Record.Height!.Value);

        if (layout is null || layout.CanvasWidth <= 0) return;

        _annotationCanvas.Layout = layout;
        _annotationCanvas.DisplayScale = previewWidth / layout.CanvasWidth;
        _annotationCanvas.Width = previewWidth;
        _annotationCanvas.Height = previewHeight;
        _annotationCanvas.Redraw();
    }

    // MARK: - Settings

    private void OnPatternChanged(object sender, TextChangedEventArgs e) => UpdatePatternPreview();

    private void UpdatePatternPreview()
    {
        var resolved = _core.ResolveFilename(
            PatternBox.Text, "window", "Explorer", "Example", 1920, 1080, _counter + 1);
        PatternPreview.Text = $"Preview:  {resolved}.png";
    }

    private void LoadCoreInfo()
    {
        var presets = _core.BackgroundPresets;
        var languages = _core.SyntaxLanguages;

        CoreStatusText.Text =
            $"pixcap_ffi loaded: {presets.Count} background presets, {languages.Count} syntax languages, " +
            $"{_core.SyntaxThemes.Count} code themes.";

        // Presets are listed to make the shared catalogue visible; they are not
        // selectable yet because Windows cannot render a beautified canvas.
        PresetList.ItemsSource = presets.Select(preset => preset.Name).ToList();

        StatusText.Text = $"Shared core loaded  -  {presets.Count} presets, {languages.Count} languages";
        UpdatePatternPreview();
    }

    private static string Sanitize(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray());
    }
}
