using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace PixCapWin.Capture;

/// <summary>
/// Screen capture via Windows.Graphics.Capture — the Windows counterpart to
/// ScreenCaptureKit on macOS.
///
/// Windows gates capture through the GraphicsCapturePicker rather than a
/// system permission dialog, so the user chooses the display or window at
/// capture time and no TCC-style pre-flight is needed.
/// </summary>
public sealed class ScreenCaptureEngine
{
    /// <summary>
    /// Captures a display or window chosen by the user.
    /// </summary>
    /// <param name="windowHandle">HWND of the window that owns the picker.</param>
    /// <returns>PNG bytes plus pixel dimensions, or null if the user cancelled.</returns>
    public async Task<CaptureResult?> CaptureWithPickerAsync(IntPtr windowHandle)
    {
        if (!GraphicsCaptureSession.IsSupported())
        {
            throw new NotSupportedException("Windows.Graphics.Capture is unavailable on this system.");
        }

        var picker = new GraphicsCapturePicker();
        // WinUI 3 has no implicit window context, so the picker must be told
        // which window it belongs to or it never appears.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);

        GraphicsCaptureItem? item = await picker.PickSingleItemAsync();
        if (item is null) return null;

        return await CaptureItemAsync(item);
    }

    /// <summary>
    /// Captures every attached display, whole, with its position on the
    /// desktop.
    ///
    /// This is the first half of region capture. Windows has no region picker,
    /// and unlike macOS there is no reliable way to hold a live overlay above
    /// the screen and keep it out of the shot, so the order is inverted: the
    /// displays are captured first and the selection is then made against the
    /// frozen image. The overlay cannot appear in a capture that already
    /// happened.
    /// </summary>
    public async Task<IReadOnlyList<DisplayCapture>> CaptureDisplaysAsync()
    {
        if (!GraphicsCaptureSession.IsSupported())
        {
            throw new NotSupportedException("Windows.Graphics.Capture is unavailable on this system.");
        }

        var captures = new List<DisplayCapture>();

        foreach (var (monitor, bounds) in MonitorInterop.Enumerate())
        {
            var item = MonitorInterop.CreateCaptureItem(monitor);
            if (item is null) continue;

            var frame = await CaptureItemAsync(item);
            captures.Add(new DisplayCapture(
                frame, bounds.Left, bounds.Top,
                bounds.Right - bounds.Left, bounds.Bottom - bounds.Top));
        }

        if (captures.Count == 0)
        {
            throw new InvalidOperationException("No display could be captured.");
        }

        return captures;
    }

    /// <summary>
    /// Cuts a rectangle out of an encoded PNG and re-encodes it.
    /// </summary>
    /// <remarks>
    /// The bounds are pixels in the source image. Anything outside it is
    /// clamped away, so a selection that ran off the edge still produces a
    /// valid crop rather than a decoder error.
    /// </remarks>
    public static async Task<CaptureResult> CropAsync(CaptureResult source, int x, int y, int width, int height)
    {
        var left = Math.Clamp(x, 0, Math.Max(0, source.Width - 1));
        var top = Math.Clamp(y, 0, Math.Max(0, source.Height - 1));
        var cropWidth = Math.Clamp(width, 1, source.Width - left);
        var cropHeight = Math.Clamp(height, 1, source.Height - top);

        using var input = new InMemoryRandomAccessStream();
        await input.WriteAsync(source.PngBytes.AsBuffer());
        input.Seek(0);

        var decoder = await BitmapDecoder.CreateAsync(input);

        // Bounds are applied after any scaling, so the scaled size has to be
        // restated as the native size or the crop lands somewhere else.
        var transform = new BitmapTransform
        {
            ScaledWidth = decoder.PixelWidth,
            ScaledHeight = decoder.PixelHeight,
            Bounds = new BitmapBounds
            {
                X = (uint)left,
                Y = (uint)top,
                Width = (uint)cropWidth,
                Height = (uint)cropHeight
            }
        };

        var pixels = await decoder.GetPixelDataAsync(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);

        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)cropWidth, (uint)cropHeight, 96, 96, pixels.DetachPixelData());
        await encoder.FlushAsync();

        var bytes = new byte[output.Size];
        using var reader = new DataReader(output.GetInputStreamAt(0));
        await reader.LoadAsync((uint)output.Size);
        reader.ReadBytes(bytes);

        return new CaptureResult(bytes, cropWidth, cropHeight, source.Title);
    }

    /// <summary>Captures a single frame from a capture item.</summary>
    public async Task<CaptureResult> CaptureItemAsync(GraphicsCaptureItem item)
    {
        var device = Direct3D11Helper.CreateDevice();

        using var framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            device,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            1,
            item.Size);

        using var session = framePool.CreateCaptureSession(item);

        // Windows 11 draws a yellow border around captured content by default;
        // switching it off keeps the capture clean. The property does not exist
        // before Windows 11 22000, so it is probed at runtime rather than
        // assumed — the app still targets Windows 10 as a minimum.
        if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent(
                "Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
        {
            session.IsBorderRequired = false;
        }

        var completion = new TaskCompletionSource<Direct3D11CaptureFrame>();
        framePool.FrameArrived += (pool, _) =>
        {
            var frame = pool.TryGetNextFrame();
            if (frame is not null) completion.TrySetResult(frame);
        };

        session.StartCapture();

        using var frame = await completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var bytes = await EncodePngAsync(frame.Surface, item.Size.Width, item.Size.Height);

        return new CaptureResult(bytes, item.Size.Width, item.Size.Height, item.DisplayName);
    }

    private static async Task<byte[]> EncodePngAsync(IDirect3DSurface surface, int width, int height)
    {
        var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(surface, BitmapAlphaMode.Premultiplied);

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();

        var buffer = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(buffer);
        return buffer;
    }
}

/// <summary>
/// A whole display, captured, together with its rectangle on the desktop.
///
/// The process is per-monitor DPI aware, so the bounds are physical pixels and
/// need no scaling before they are compared with the captured frame.
/// </summary>
public sealed record DisplayCapture(CaptureResult Frame, int Left, int Top, int Width, int Height);

/// <summary>
/// Monitor enumeration and per-monitor capture items, neither of which WinRT
/// offers a usable projection for.
///
/// <c>GraphicsCaptureItem.TryCreateFromDisplayId</c> looks like the modern
/// answer, but it counts as programmatic capture and Windows answers
/// <c>DeniedByUser</c> for an app without package identity — which this one is,
/// deliberately, so it can run from a folder. <c>IGraphicsCaptureItemInterop</c>
/// is the older Win32 entry point, carries no such gate, and is what every
/// desktop capture tool uses.
/// </summary>
internal static class MonitorInterop
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr context, ref Rect bounds, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(
        IntPtr deviceContext, IntPtr clip, MonitorEnumProc callback, IntPtr data);

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern IntPtr WindowsCreateString(
        [MarshalAs(UnmanagedType.LPWStr)] string source, int length);

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern void WindowsDeleteString(IntPtr text);

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern IntPtr RoGetActivationFactory(IntPtr classId, ref Guid iid);

    private static readonly Guid IGraphicsCaptureItemInterop =
        new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");

    private static readonly Guid IGraphicsCaptureItem =
        new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    /// <summary>Builds a capture item for one monitor, or null if Windows refuses.</summary>
    public static GraphicsCaptureItem? CreateCaptureItem(IntPtr monitor)
    {
        const string ClassName = "Windows.Graphics.Capture.GraphicsCaptureItem";

        var classId = WindowsCreateString(ClassName, ClassName.Length);
        var factory = IntPtr.Zero;
        var raw = IntPtr.Zero;

        try
        {
            var interopIid = IGraphicsCaptureItemInterop;
            factory = RoGetActivationFactory(classId, ref interopIid);
            if (factory == IntPtr.Zero) return null;

            // Called through the vtable rather than a ComImport interface so it
            // does not depend on which COM interop mode the app is built with.
            // Slot 4: QueryInterface, AddRef, Release, CreateForWindow, then
            // CreateForMonitor.
            unsafe
            {
                var vtable = *(IntPtr**)factory;
                var createForMonitor =
                    (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtable[4];

                var itemIid = IGraphicsCaptureItem;
                IntPtr result;
                var hr = createForMonitor(factory, monitor, &itemIid, &result);

                if (hr < 0 || result == IntPtr.Zero) return null;
                raw = result;
            }

            return WinRT.MarshalInspectable<GraphicsCaptureItem>.FromAbi(raw);
        }
        finally
        {
            if (raw != IntPtr.Zero) Marshal.Release(raw);
            if (factory != IntPtr.Zero) Marshal.Release(factory);
            if (classId != IntPtr.Zero) WindowsDeleteString(classId);
        }
    }

    public static List<(IntPtr Monitor, Rect Bounds)> Enumerate()
    {
        var monitors = new List<(IntPtr, Rect)>();

        // The callback is held in a local for the duration of the call; letting
        // the delegate be collected mid-enumeration would crash in native code.
        MonitorEnumProc callback = (IntPtr monitor, IntPtr _, ref Rect bounds, IntPtr _) =>
        {
            monitors.Add((monitor, bounds));
            return true;
        };

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        GC.KeepAlive(callback);

        return monitors;
    }
}

public sealed record CaptureResult(byte[] PngBytes, int Width, int Height, string? Title)
{
    public async Task<string> SaveAsync(string directory, string fileName)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, fileName + ".png");

        var counter = 2;
        while (File.Exists(path))
        {
            path = Path.Combine(directory, $"{fileName} {counter}.png");
            counter++;
        }

        await File.WriteAllBytesAsync(path, PngBytes);
        return path;
    }
}

/// <summary>
/// Creates the Direct3D device the capture frame pool needs.
///
/// Windows.Graphics.Capture will only accept an IDirect3DDevice, and the only
/// way to get one is to build an ID3D11Device, query it for IDXGIDevice, and
/// hand that to CreateDirect3D11DeviceFromDXGIDevice. Every intermediate
/// pointer is released — a leak here would pin the GPU device for the life of
/// the process.
/// </summary>
internal static class Direct3D11Helper
{
    private static readonly Guid IID_IDXGIDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");

    private const uint D3D_DRIVER_TYPE_HARDWARE = 1;
    private const uint D3D_DRIVER_TYPE_WARP = 5;
    private const uint D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
    private const uint D3D11_SDK_VERSION = 7;

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int D3D11CreateDevice(
        IntPtr adapter, uint driverType, IntPtr software, uint flags,
        IntPtr featureLevels, uint featureLevelCount, uint sdkVersion,
        out IntPtr device, out uint featureLevel, out IntPtr immediateContext);

    [DllImport("d3d11.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern IntPtr CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice);

    public static IDirect3DDevice CreateDevice()
    {
        // Hardware first; a VM without GPU passthrough falls back to WARP,
        // which is exactly the Parallels case.
        if (!TryCreate(D3D_DRIVER_TYPE_HARDWARE, out var device) &&
            !TryCreate(D3D_DRIVER_TYPE_WARP, out device))
        {
            throw new InvalidOperationException(
                "Could not create a Direct3D 11 device for screen capture.");
        }

        return device!;
    }

    private static bool TryCreate(uint driverType, out IDirect3DDevice? device)
    {
        device = null;

        IntPtr d3dDevice = IntPtr.Zero;
        IntPtr context = IntPtr.Zero;
        IntPtr dxgiDevice = IntPtr.Zero;
        IntPtr inspectable = IntPtr.Zero;

        try
        {
            var hr = D3D11CreateDevice(
                IntPtr.Zero, driverType, IntPtr.Zero,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                IntPtr.Zero, 0, D3D11_SDK_VERSION,
                out d3dDevice, out _, out context);

            if (hr < 0 || d3dDevice == IntPtr.Zero) return false;

            var iid = IID_IDXGIDevice;
            if (Marshal.QueryInterface(d3dDevice, ref iid, out dxgiDevice) < 0) return false;

            inspectable = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice);
            if (inspectable == IntPtr.Zero) return false;

            device = WinRT.MarshalInspectable<IDirect3DDevice>.FromAbi(inspectable);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (inspectable != IntPtr.Zero) Marshal.Release(inspectable);
            if (dxgiDevice != IntPtr.Zero) Marshal.Release(dxgiDevice);
            if (context != IntPtr.Zero) Marshal.Release(context);
            if (d3dDevice != IntPtr.Zero) Marshal.Release(d3dDevice);
        }
    }
}
