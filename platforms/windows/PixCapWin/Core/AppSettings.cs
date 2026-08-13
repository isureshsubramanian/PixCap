using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using PixCapWin.Capture;

namespace PixCapWin.Core;

/// <summary>
/// Preferences that belong to this machine rather than to a document.
///
/// Kept beside the history database in LocalApplicationData, as plain JSON: it
/// is a handful of values, and a file the user can read and delete is easier to
/// support than a registry key. Anything that has to mean the same thing on
/// both platforms belongs in the shared core instead, not here.
/// </summary>
public sealed class AppSettings
{
    private static readonly JsonSerializerOptions Format = new() { WriteIndented = true };

    [JsonPropertyName("capture_area_hotkey")]
    public HotkeyBinding? CaptureAreaHotkey { get; set; }

    /// <summary>Last annotation colour, so a preference outlives the session.</summary>
    [JsonPropertyName("annotation_color")]
    public string AnnotationColorHex { get; set; } = "#FF3366";

    [JsonIgnore]
    public HotkeyBinding EffectiveHotkey =>
        CaptureAreaHotkey is { IsUsable: true } binding ? binding : HotkeyBinding.Default;

    [JsonIgnore]
    private string? _path;

    public static AppSettings Load(string path)
    {
        AppSettings settings;

        try
        {
            settings = File.Exists(path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new AppSettings()
                : new AppSettings();
        }
        catch
        {
            // A corrupt or half-written file should cost the user their
            // preferences, not the app's ability to start.
            settings = new AppSettings();
        }

        settings._path = path;
        return settings;
    }

    public void Save()
    {
        if (_path is null) return;

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(this, Format));
        }
        catch
        {
            // Not worth interrupting a capture over.
        }
    }
}
