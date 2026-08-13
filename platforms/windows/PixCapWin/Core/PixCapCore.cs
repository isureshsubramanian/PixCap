using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace PixCapWin.Core;

/// <summary>
/// P/Invoke bindings to the shared Rust core (pixcap_ffi.dll).
///
/// This is the same C ABI the macOS app calls through Swift, so background
/// presets, file naming, the history database, and syntax highlighting behave
/// identically on both platforms. Sharing the core rather than the UI is what
/// lets each shell stay native while the behaviour stays consistent.
/// </summary>
internal static class NativeMethods
{
    private const string Library = "pixcap_ffi";

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_theme_presets_json();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_syntax_languages_json();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_syntax_themes_json();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_default_naming_pattern();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_render_snippet(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string code,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string language,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? syntaxTheme);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_resolve_filename(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pattern,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string mode,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? appName,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? windowTitle,
        uint width, uint height, uint counter);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void pixcap_free_string(IntPtr pointer);

    // History
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_history_open([MarshalAs(UnmanagedType.LPUTF8Str)] string dbPath);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void pixcap_history_close(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern long pixcap_history_insert(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string recordJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_history_recent(IntPtr handle, long limit);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_history_search(IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int pixcap_history_delete(IntPtr handle, long id);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int pixcap_history_toggle_favorite(IntPtr handle, long id);

    // Documents
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int pixcap_document_write(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string documentJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_document_read([MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_document_sidecar_path([MarshalAs(UnmanagedType.LPUTF8Str)] string imagePath);

    // Beautification
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int pixcap_render_document(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string imagePath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string documentJson,
        float scale,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string outputPath);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_render_layout(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string documentJson,
        uint sourceWidth, uint sourceHeight);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_render_canvas_size(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string documentJson,
        uint sourceWidth, uint sourceHeight);

    // Scrolling capture
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr pixcap_stitch_scroll_frames(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pathsJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string outputPath);

    /// <summary>Takes ownership of a Rust-allocated string, converting and freeing it.</summary>
    internal static string? Consume(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return null;
        try
        {
            return Marshal.PtrToStringUTF8(pointer);
        }
        finally
        {
            pixcap_free_string(pointer);
        }
    }
}

/// <summary>
/// Canvas settings for a render, serialised into the shared document schema.
///
/// The same structure the .pixcap.json sidecar stores, so what is rendered and
/// what could later be re-edited are the same data.
/// </summary>
public sealed class BeautifyOptions
{
    public string BackgroundPreset { get; set; } = "amethyst";
    public double Padding { get; set; } = 48;
    public double CornerRadius { get; set; } = 14;
    public double ShadowBlur { get; set; } = 30;
    public double ShadowOpacity { get; set; } = 0.35;
    public string FrameStyle { get; set; } = "macOS";
    public string AspectRatio { get; set; } = "Auto";
    public string? FrameTitle { get; set; }
    public string Texture { get; set; } = "None";
    public double NoiseIntensity { get; set; }
    /// <summary>Non-destructive crop as x, y, width, height in source points.</summary>
    public double[]? Crop { get; set; }

    public string ToDocumentJson(string sourceImage,
                                 IReadOnlyList<Views.AnnotationItem>? items = null)
    {
        var canvas = new JsonObject
        {
            ["background_kind"] = "preset",
            ["background_value"] = BackgroundPreset,
            ["padding"] = Padding,
            ["corner_radius"] = CornerRadius,
            ["shadow_blur"] = ShadowBlur,
            ["shadow_opacity"] = ShadowOpacity,
            ["frame_style"] = FrameStyle,
            ["aspect_ratio"] = AspectRatio,
            ["frame_title"] = FrameTitle,
            ["texture"] = Texture,
            ["noise_intensity"] = NoiseIntensity
        };

        if (Crop is { Length: 4 })
        {
            canvas["crop"] = new JsonArray(Crop[0], Crop[1], Crop[2], Crop[3]);
        }

        var layer = new JsonArray();
        if (items is not null)
        {
            foreach (var item in items) layer.Add(item.ToJson());
        }

        var document = new JsonObject
        {
            ["version"] = 1,
            ["source_image"] = sourceImage,
            ["canvas"] = canvas,
            ["items"] = layer
        };

        return document.ToJsonString();
    }
}

public sealed record BackgroundPreset(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name);

public sealed record SyntaxLanguage(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("extensions")] string[] Extensions);

public sealed class ScreenshotRecord
{
    [JsonPropertyName("id")] public long Id { get; set; }
    [JsonPropertyName("filepath")] public string Filepath { get; set; } = "";
    [JsonPropertyName("thumbnail_path")] public string? ThumbnailPath { get; set; }
    [JsonPropertyName("captured_at")] public string CapturedAt { get; set; } = "";
    [JsonPropertyName("capture_mode")] public string? CaptureMode { get; set; }
    [JsonPropertyName("width")] public long? Width { get; set; }
    [JsonPropertyName("height")] public long? Height { get; set; }
    [JsonPropertyName("ocr_text")] public string? OcrText { get; set; }
    [JsonPropertyName("tags")] public string? Tags { get; set; }
    [JsonPropertyName("is_favorited")] public bool IsFavorited { get; set; }
}

/// <summary>Managed façade over the shared core.</summary>
public sealed class PixCapCore : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private IntPtr _history = IntPtr.Zero;
    private readonly object _historyLock = new();

    /// <summary>Background presets, defined once in Rust and shared with macOS.</summary>
    public IReadOnlyList<BackgroundPreset> BackgroundPresets =>
        Deserialize<BackgroundPreset[]>(NativeMethods.Consume(NativeMethods.pixcap_theme_presets_json())) ?? [];

    public IReadOnlyList<SyntaxLanguage> SyntaxLanguages =>
        Deserialize<SyntaxLanguage[]>(NativeMethods.Consume(NativeMethods.pixcap_syntax_languages_json())) ?? [];

    public IReadOnlyList<string> SyntaxThemes =>
        Deserialize<string[]>(NativeMethods.Consume(NativeMethods.pixcap_syntax_themes_json())) ?? [];

    public string DefaultNamingPattern =>
        NativeMethods.Consume(NativeMethods.pixcap_default_naming_pattern()) ?? "PixCap_{date}_{time}_{counter}";

    public string ResolveFilename(string pattern, string mode, string? appName, string? windowTitle,
                                  int width, int height, int counter) =>
        NativeMethods.Consume(NativeMethods.pixcap_resolve_filename(
            pattern, mode, appName, windowTitle,
            (uint)Math.Max(0, width), (uint)Math.Max(0, height), (uint)Math.Max(0, counter))) ?? pattern;

    public string? RenderSnippetSvg(string code, string language, string theme = "base16-ocean.dark") =>
        NativeMethods.Consume(NativeMethods.pixcap_render_snippet(code, language, theme));

    // --- History -----------------------------------------------------------
    //
    // The SQLite connection behind the handle is not thread-safe, so every call
    // is serialised, mirroring the macOS side's dedicated queue.

    public void OpenHistory(string databasePath)
    {
        lock (_historyLock)
        {
            if (_history != IntPtr.Zero) return;
            _history = NativeMethods.pixcap_history_open(databasePath);
        }
    }

    public long InsertHistory(ScreenshotRecord record)
    {
        lock (_historyLock)
        {
            if (_history == IntPtr.Zero) return -1;
            return NativeMethods.pixcap_history_insert(_history, JsonSerializer.Serialize(record, JsonOptions));
        }
    }

    public IReadOnlyList<ScreenshotRecord> RecentHistory(int limit = 200)
    {
        lock (_historyLock)
        {
            if (_history == IntPtr.Zero) return [];
            return Deserialize<ScreenshotRecord[]>(
                NativeMethods.Consume(NativeMethods.pixcap_history_recent(_history, limit))) ?? [];
        }
    }

    public IReadOnlyList<ScreenshotRecord> SearchHistory(string query)
    {
        lock (_historyLock)
        {
            if (_history == IntPtr.Zero) return [];
            return Deserialize<ScreenshotRecord[]>(
                NativeMethods.Consume(NativeMethods.pixcap_history_search(_history, query))) ?? [];
        }
    }

    public void DeleteHistory(long id)
    {
        lock (_historyLock)
        {
            if (_history != IntPtr.Zero) NativeMethods.pixcap_history_delete(_history, id);
        }
    }

    public void ToggleFavorite(long id)
    {
        lock (_historyLock)
        {
            if (_history != IntPtr.Zero) NativeMethods.pixcap_history_toggle_favorite(_history, id);
        }
    }

    // --- Beautification ---------------------------------------------------

    /// <summary>
    /// Renders a beautified PNG from a source image and a document.
    /// </summary>
    /// <param name="scale">Output pixels per canvas point; 2.0 for a Retina-quality export.</param>
    /// <returns>True when the file was written.</returns>
    public bool RenderDocument(string imagePath, BeautifyOptions options, float scale, string outputPath,
                               IReadOnlyList<Views.AnnotationItem>? items = null)
    {
        var json = options.ToDocumentJson(imagePath, items);
        return NativeMethods.pixcap_render_document(imagePath, json, scale, outputPath) == 0;
    }

    /// <summary>
    /// Canvas size a document would render to, in points. Lets the UI report
    /// dimensions without rendering first.
    /// </summary>
    public (double Width, double Height)? CanvasSize(string imagePath, BeautifyOptions options,
                                                    int sourceWidth, int sourceHeight)
    {
        var json = options.ToDocumentJson(imagePath);
        var result = NativeMethods.Consume(
            NativeMethods.pixcap_render_canvas_size(json, (uint)sourceWidth, (uint)sourceHeight));

        if (result is null) return null;

        try
        {
            using var document = JsonDocument.Parse(result);
            return (
                document.RootElement.GetProperty("width").GetDouble(),
                document.RootElement.GetProperty("height").GetDouble());
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Canvas geometry for a document, straight from the renderer.
    ///
    /// The editor needs this to map a pointer position into image space.
    /// Taking the renderer's own numbers keeps the editor and the output in
    /// agreement rather than duplicating the layout arithmetic in C#.
    /// </summary>
    public Views.RenderLayout? Layout(string imagePath, BeautifyOptions options,
                                      IReadOnlyList<Views.AnnotationItem>? items,
                                      int sourceWidth, int sourceHeight)
    {
        var json = options.ToDocumentJson(imagePath, items);
        var result = NativeMethods.Consume(
            NativeMethods.pixcap_render_layout(json, (uint)sourceWidth, (uint)sourceHeight));

        if (result is null) return null;

        try
        {
            using var document = JsonDocument.Parse(result);
            var root = document.RootElement;
            return new Views.RenderLayout
            {
                CanvasWidth = root.GetProperty("canvas_width").GetDouble(),
                CanvasHeight = root.GetProperty("canvas_height").GetDouble(),
                ImageX = root.GetProperty("image_x").GetDouble(),
                ImageY = root.GetProperty("image_y").GetDouble(),
                ImageWidth = root.GetProperty("image_width").GetDouble(),
                ImageHeight = root.GetProperty("image_height").GetDouble(),
                CropX = root.GetProperty("crop_x").GetDouble(),
                CropY = root.GetProperty("crop_y").GetDouble()
            };
        }
        catch
        {
            return null;
        }
    }

    public string SidecarPath(string imagePath) =>
        NativeMethods.Consume(NativeMethods.pixcap_document_sidecar_path(imagePath)) ?? imagePath + ".pixcap.json";

    private static T? Deserialize<T>(string? json) =>
        string.IsNullOrEmpty(json) ? default : JsonSerializer.Deserialize<T>(json, JsonOptions);

    public void Dispose()
    {
        lock (_historyLock)
        {
            if (_history != IntPtr.Zero)
            {
                NativeMethods.pixcap_history_close(_history);
                _history = IntPtr.Zero;
            }
        }
    }
}
