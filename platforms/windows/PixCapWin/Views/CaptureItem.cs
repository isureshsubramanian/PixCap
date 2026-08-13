using System;
using System.IO;
using Microsoft.UI.Xaml.Media.Imaging;
using PixCapWin.Core;

namespace PixCapWin.Views;

/// <summary>
/// A history row prepared for display: thumbnail, readable title, and subtitle.
///
/// The raw <see cref="ScreenshotRecord"/> carries a full path and an ISO
/// timestamp, neither of which belongs in a list. Formatting happens here so
/// the XAML can bind directly without converters.
/// </summary>
public sealed class CaptureItem
{
    public ScreenshotRecord Record { get; }

    public CaptureItem(ScreenshotRecord record)
    {
        Record = record;
    }

    public long Id => Record.Id;

    public string FilePath => Record.Filepath;

    /// <summary>File name without the directory or extension.</summary>
    public string Title
    {
        get
        {
            var name = Path.GetFileNameWithoutExtension(Record.Filepath);
            return string.IsNullOrWhiteSpace(name) ? "Untitled capture" : name;
        }
    }

    /// <summary>Relative time plus dimensions, e.g. "2 minutes ago · 1612 × 920".</summary>
    public string Subtitle
    {
        get
        {
            var parts = new System.Collections.Generic.List<string>();

            if (DateTimeOffset.TryParse(Record.CapturedAt, out var captured))
            {
                parts.Add(Humanize(DateTimeOffset.UtcNow - captured));
            }

            if (Record.Width is > 0 && Record.Height is > 0)
            {
                parts.Add($"{Record.Width} × {Record.Height}");
            }

            if (!string.IsNullOrWhiteSpace(Record.CaptureMode))
            {
                parts.Add(Record.CaptureMode!);
            }

            return string.Join("  ·  ", parts);
        }
    }

    /// <summary>First line of recognised text, when the capture had any.</summary>
    public string TextPreview
    {
        get
        {
            if (string.IsNullOrWhiteSpace(Record.OcrText)) return string.Empty;
            var firstLine = Record.OcrText!.Split('\n')[0].Trim();
            return firstLine.Length > 90 ? firstLine[..90] + "…" : firstLine;
        }
    }

    public bool HasText => !string.IsNullOrWhiteSpace(TextPreview);

    public bool FileExists => File.Exists(Record.Filepath);

    /// <summary>
    /// Thumbnail loaded from disk, decoded at display width so a 4K capture
    /// does not sit in memory at full size for a 220px tile.
    /// </summary>
    public BitmapImage? Thumbnail
    {
        get
        {
            var source = Record.ThumbnailPath is not null && File.Exists(Record.ThumbnailPath)
                ? Record.ThumbnailPath
                : Record.Filepath;

            if (!File.Exists(source)) return null;

            try
            {
                var bitmap = new BitmapImage
                {
                    DecodePixelWidth = 480,
                    CreateOptions = BitmapCreateOptions.IgnoreImageCache
                };
                bitmap.UriSource = new Uri(source);
                return bitmap;
            }
            catch
            {
                return null;
            }
        }
    }

    private static string Humanize(TimeSpan elapsed)
    {
        if (elapsed.TotalSeconds < 60) return "just now";
        if (elapsed.TotalMinutes < 60) return $"{(int)elapsed.TotalMinutes} min ago";
        if (elapsed.TotalHours < 24) return $"{(int)elapsed.TotalHours} h ago";
        if (elapsed.TotalDays < 7) return $"{(int)elapsed.TotalDays} d ago";
        return DateTimeOffset.UtcNow.Subtract(elapsed).LocalDateTime.ToString("d MMM yyyy");
    }
}
