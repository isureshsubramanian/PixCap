using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json.Serialization;
using System.Windows.Forms;

namespace PixCapWin.Capture;

/// <summary>
/// A system-wide shortcut, as Windows understands one.
///
/// Stored as modifier flags plus a virtual-key code rather than as a string,
/// because that is exactly what <c>RegisterHotKey</c> takes; the display text
/// is derived, never parsed back.
/// </summary>
public sealed record HotkeyBinding(
    [property: JsonPropertyName("modifiers")] uint Modifiers,
    [property: JsonPropertyName("key")] uint Key)
{
    public const uint Alt = 0x0001;
    public const uint Control = 0x0002;
    public const uint Shift = 0x0004;
    public const uint Windows = 0x0008;

    /// <summary>
    /// Win+Alt+S. Win+Shift+S belongs to the Snipping Tool and cannot be taken,
    /// and plain Ctrl+Shift combinations are heavily used by other apps.
    /// </summary>
    public static HotkeyBinding Default { get; } = new(Windows | Alt, (uint)Keys.S);

    [JsonIgnore]
    public bool IsUsable => Key != 0 && Modifiers != 0;

    /// <summary>Human-readable form, in the order Windows writes shortcuts.</summary>
    public override string ToString()
    {
        if (!IsUsable) return "None";

        var parts = new List<string>();
        if ((Modifiers & Windows) != 0) parts.Add("Win");
        if ((Modifiers & Control) != 0) parts.Add("Ctrl");
        if ((Modifiers & Alt) != 0) parts.Add("Alt");
        if ((Modifiers & Shift) != 0) parts.Add("Shift");
        parts.Add(Describe((Keys)Key));

        return string.Join("+", parts);
    }

    private static string Describe(Keys key) => key switch
    {
        >= Keys.D0 and <= Keys.D9 => ((char)('0' + (key - Keys.D0))).ToString(),
        >= Keys.A and <= Keys.Z => key.ToString(),
        >= Keys.F1 and <= Keys.F24 => key.ToString(),
        Keys.Oemcomma => ",",
        Keys.OemPeriod => ".",
        Keys.OemQuestion => "/",
        Keys.OemMinus => "-",
        Keys.Oemplus => "=",
        Keys.Space => "Space",
        Keys.PrintScreen => "PrtScn",
        Keys.Insert => "Insert",
        _ => key.ToString()
    };
}

/// <summary>
/// Receives the shortcut when the app does not have focus.
///
/// A hidden window rather than the main one: WinUI 3 gives no way to see raw
/// messages for its own HWND without subclassing it, and <c>WM_HOTKEY</c> is
/// posted to whichever window registered. Windows Forms is already referenced
/// for the region overlay, and its <c>NativeWindow</c> is the smallest thing
/// that owns a window procedure. WinUI's own message loop dispatches to it,
/// because both live on the same thread.
/// </summary>
public sealed class HotkeyListener : NativeWindow, IDisposable
{
    private const int WmHotkey = 0x0312;
    private const int Id = 0x5058;              // "PX"
    private const uint NoRepeat = 0x4000;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr window, int id);

    private bool _registered;

    /// <summary>Raised on the UI thread when the shortcut is pressed.</summary>
    public event EventHandler? Pressed;

    public HotkeyListener()
    {
        CreateHandle(new CreateParams
        {
            Caption = "PixCap hotkey sink",
            // Message-only: never shown, never in the taskbar, still receives
            // everything posted to it.
            Parent = new IntPtr(-3)
        });
    }

    /// <summary>
    /// Claims the shortcut, releasing any previous one.
    /// </summary>
    /// <returns>
    /// False when Windows refuses, which in practice means another application
    /// already owns that combination. The caller should say so rather than
    /// leave the user wondering why nothing happens.
    /// </returns>
    public bool Register(HotkeyBinding binding)
    {
        Release();

        if (!binding.IsUsable) return false;

        // NoRepeat: holding the keys down should capture once, not once per
        // keyboard repeat.
        _registered = RegisterHotKey(Handle, Id, binding.Modifiers | NoRepeat, binding.Key);
        return _registered;
    }

    public void Release()
    {
        if (!_registered) return;
        UnregisterHotKey(Handle, Id);
        _registered = false;
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey && message.WParam.ToInt32() == Id)
        {
            Pressed?.Invoke(this, EventArgs.Empty);
            return;
        }

        base.WndProc(ref message);
    }

    public void Dispose()
    {
        Release();
        if (Handle != IntPtr.Zero) DestroyHandle();
    }
}
