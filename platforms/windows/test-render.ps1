<#
.SYNOPSIS
    Renders a beautified image by calling the Rust core directly.

.DESCRIPTION
    Calls pixcap_render_document in pixcap_ffi.dll through P/Invoke, so the
    renderer can be exercised without waiting on the C# app to wire it up.
    This is the same entry point the Windows app will use.

.PARAMETER Image
    Source image. Defaults to the newest PNG in Pictures\PixCap.

.PARAMETER Preset
    Background preset id: azure-mesh, oceanic, amethyst, sunset-glow,
    neon-pulse, midnight, linen, graphite, glass-dark, transparent.

.PARAMETER Frame
    Window chrome: macOS, Windows, Minimal, None.

.PARAMETER Texture
    Canvas texture: None, Grain, Paper, Linen, Dots, Grid.

.EXAMPLE
    .\test-render.ps1
    .\test-render.ps1 -Preset sunset-glow -Texture Grid -Padding 80
    .\test-render.ps1 -Image C:\shots\demo.png -Frame Minimal -Annotate
#>

[CmdletBinding()]
param(
    [string]$Image,
    [string]$Preset = 'amethyst',
    [ValidateSet('macOS', 'Windows', 'Minimal', 'None')]
    [string]$Frame = 'macOS',
    [ValidateSet('None', 'Grain', 'Paper', 'Linen', 'Dots', 'Grid')]
    [string]$Texture = 'None',
    [double]$Padding = 48,
    [double]$CornerRadius = 14,
    [double]$ShadowBlur = 30,
    [double]$Grain = 0,
    [double]$Scale = 2.0,
    [string]$Title = 'PixCap',
    [switch]$Annotate,
    [string]$Output
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..\..')

# Find the DLL: architecture-specific build first, then the host build.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$candidates = @(
    (Join-Path $repoRoot "target\$arch\release\pixcap_ffi.dll"),
    (Join-Path $repoRoot 'target\release\pixcap_ffi.dll')
)

$dll = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dll) {
    Write-Error "pixcap_ffi.dll not found. Build it first: cargo build --release --target $arch"
    exit 1
}
Write-Host "Core: $dll" -ForegroundColor DarkGray

# Load a copy rather than the build output.
#
# P/Invoke maps the DLL into this PowerShell process and keeps it mapped until
# the process exits. Loading it straight from target\ locks the file, and the
# next `cargo build` fails with "Access is denied" - from a shell that looks
# idle. Copying to temp leaves the build directory free.
$loadPath = Join-Path ([IO.Path]::GetTempPath()) ("pixcap_ffi_" + [Guid]::NewGuid().ToString('N') + ".dll")
Copy-Item -Path $dll -Destination $loadPath -Force
Write-Host "Loaded from: $loadPath" -ForegroundColor DarkGray

# Source image.
#
# Renders are excluded when picking automatically: the output is the newest PNG
# in the folder after the first run, so without this the script beautifies its
# own output, compounding padding until the decoder refuses the file.
if (-not $Image) {
    $pictures = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'PixCap'
    $newest = Get-ChildItem -Path $pictures -Filter *.png -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -notlike '*-beautified*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        Write-Error "No original PNG found in $pictures. Capture something first, or pass -Image."
        exit 1
    }
    $Image = $newest.FullName
}

if (-not (Test-Path $Image)) {
    Write-Error "Image not found: $Image"
    exit 1
}

if (-not $Output) {
    # Strip any existing suffix so re-running never chains -beautified-beautified.
    $base = [IO.Path]::GetFileNameWithoutExtension($Image) -replace '(-beautified)+$', ''
    $Output = Join-Path ([IO.Path]::GetDirectoryName($Image)) ($base + '-beautified.png')
}

if ($Output -eq $Image) {
    Write-Error "The output would overwrite the source. Pass -Output to choose another path."
    exit 1
}

Write-Host "Source: $Image" -ForegroundColor DarkGray

# Build the document. This is the same schema the .pixcap.json sidecar uses.
$canvas = [ordered]@{
    background_kind  = 'preset'
    background_value = $Preset
    padding          = $Padding
    corner_radius    = $CornerRadius
    shadow_blur      = $ShadowBlur
    shadow_opacity   = 0.35
    frame_style      = $Frame
    aspect_ratio     = 'Auto'
    frame_title      = $Title
    texture          = $Texture
    noise_intensity  = $Grain
}

$items = @()
if ($Annotate) {
    # A sample of every annotation kind, to check the renderer end to end.
    $items = @(
        [ordered]@{ tool = 'rectangle'; start = @(40, 40);  end = @(320, 220); color_hex = '#FF3366'; stroke_width = 5 },
        [ordered]@{ tool = 'arrow';     start = @(80, 400); end = @(420, 180); color_hex = '#00E5FF'; stroke_width = 6; curved_arrow = $true; arrow_head = 'filled' },
        [ordered]@{ tool = 'counter';   start = @(460, 120); end = @(460, 120); color_hex = '#FFB300'; stroke_width = 4; number = 1 },
        [ordered]@{ tool = 'text';      start = @(60, 300); end = @(0, 0);     color_hex = '#FFFFFF'; stroke_width = 2; text = 'Rendered by Rust'; font_size = 30 },
        [ordered]@{ tool = 'blur';      start = @(360, 280); end = @(560, 380); color_hex = '#000000'; stroke_width = 1; blur_style = 'pixelate'; blur_intensity = 26 }
    )
}

$document = [ordered]@{
    version      = 1
    source_image = $Image
    canvas       = $canvas
    items        = $items
} | ConvertTo-Json -Depth 6 -Compress

# P/Invoke into the core.
#
# Written against .NET Framework, because Add-Type in Windows PowerShell 5.1
# compiles with the Framework compiler: Marshal.PtrToStringUTF8 does not exist
# there, and LPUTF8Str marshalling is unreliable. Strings are therefore passed
# as null-terminated UTF-8 byte arrays and read back byte by byte.
$signature = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PixCapRender
{
    [DllImport(@"DLL_PATH", CallingConvention = CallingConvention.Cdecl)]
    private static extern int pixcap_render_document(
        byte[] imagePath, byte[] documentJson, float scale, byte[] outputPath);

    [DllImport(@"DLL_PATH", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pixcap_render_canvas_size(
        byte[] documentJson, uint sourceWidth, uint sourceHeight);

    [DllImport(@"DLL_PATH", CallingConvention = CallingConvention.Cdecl)]
    private static extern void pixcap_free_string(IntPtr pointer);

    private static byte[] ToUtf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
        byte[] terminated = new byte[bytes.Length + 1];
        Array.Copy(bytes, terminated, bytes.Length);
        return terminated;
    }

    private static string FromUtf8(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return null;

        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0) length++;

        byte[] buffer = new byte[length];
        Marshal.Copy(pointer, buffer, 0, length);
        return Encoding.UTF8.GetString(buffer);
    }

    public static int Render(string image, string json, float scale, string output)
    {
        return pixcap_render_document(ToUtf8(image), ToUtf8(json), scale, ToUtf8(output));
    }

    public static string CanvasSize(string json, uint width, uint height)
    {
        IntPtr pointer = pixcap_render_canvas_size(ToUtf8(json), width, height);
        if (pointer == IntPtr.Zero) return "(unavailable)";
        try { return FromUtf8(pointer); }
        finally { pixcap_free_string(pointer); }
    }
}
'@.Replace('DLL_PATH', $loadPath)

Add-Type -TypeDefinition $signature -Language CSharp

# Report the canvas size the core computes, before rendering.
Add-Type -AssemblyName System.Drawing
$bitmap = [System.Drawing.Image]::FromFile($Image)
$sourceWidth = $bitmap.Width
$sourceHeight = $bitmap.Height
$bitmap.Dispose()

$size = [PixCapRender]::CanvasSize($document, $sourceWidth, $sourceHeight)
Write-Host "Source is $sourceWidth x $sourceHeight, canvas will be $size points" -ForegroundColor DarkGray

Write-Host "Rendering..." -ForegroundColor Cyan
$status = [PixCapRender]::Render($Image, $document, [float]$Scale, $Output)

if ($status -ne 0) {
    Write-Error "The renderer returned $status. Check the console for a reason."
    exit 1
}

$rendered = Get-Item $Output
$mb = [math]::Round($rendered.Length / 1KB, 1)
Write-Host ""
Write-Host "Done: $Output  ($mb KB)" -ForegroundColor Green
Write-Host "Preset $Preset, frame $Frame, texture $Texture, scale ${Scale}x"

Start-Process $Output
