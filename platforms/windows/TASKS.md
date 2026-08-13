# PixCap on Windows — working notes and open tasks

Notes on the Windows port: how it is put together, what is done, what is not,
and the reasoning behind the decisions that are not obvious from the code.

Windows work needs a Windows machine. Much of the early code was written on
macOS and compiled cleanly while still being wrong at runtime — most of the
closed bugs below are that failure mode, which is why the convention here is to
launch the app and watch it rather than trust a green build.

---

## Changing the shared core

The Rust core is shared with macOS, so a change in `crates/` reaches both apps.

- `platforms/windows/**` — self-contained, change freely
- `crates/**` — shared; adding functions, FFI entry points, or fields with
  `serde` defaults is safe, changing behaviour macOS already relies on is not
- `platforms/macos/**` — the macOS app is stable and its UI is settled; leave
  it alone unless a change is specifically about macOS

After touching `crates/`, confirm nothing on the macOS side moved with it:

```powershell
git status --short platforms/macos/
```

---

## Architecture

```
                    +---------------------------+
                    |   pixcap-core  (Rust)     |
                    |   + pixcap-ffi  (C ABI)   |
                    +---------------------------+
                     |                         |
        Swift/FFI    |                         |   C#/P-Invoke
                     v                         v
        +------------------------+   +------------------------+
        |   macOS app (Swift)    |   |  Windows app (WinUI 3) |
        |   OWN Core Graphics    |   |  USES the Rust         |
        |   renderer - untouched |   |  renderer              |
        +------------------------+   +------------------------+
```

**Two renderers, deliberately.** macOS keeps its Core Graphics renderer because
it works and looks right. Windows uses the Rust renderer in `crates/pixcap-core/src/render/`.
They are not expected to be pixel-identical. What keeps them honest is the
shared document schema (`crates/pixcap-core/src/document/`): a `.pixcap.json`
written on either platform means the same thing on the other.

### Shared through the FFI

Presets, file naming, history (SQLite + FTS5), syntax highlighting, scrolling
stitcher, document read/write, and — for Windows only — rendering.

Bindings: `platforms/windows/PixCapWin/Core/PixCapCore.cs`
FFI surface: `crates/pixcap-ffi/src/lib.rs`

---

## Build and run

The app is published **framework-dependent**, so a machine running it needs two
things from Microsoft:

| Prerequisite | Why |
|:--|:--|
| .NET Desktop Runtime 8 or newer | `RollForward=LatestMajor`, so a newer .NET counts |
| Windows App Runtime 1.6 | WinUI 3; the version is pinned by the SDK package |

The installer detects both and fetches only what is missing, which is why it is
10 MB rather than 64. Bundling them instead would freeze copies that never
receive a security patch.

```powershell
# Shared core, matching the machine architecture
rustup target add aarch64-pc-windows-msvc          # or x86_64-pc-windows-msvc
cargo build --release --target aarch64-pc-windows-msvc

# App
cd platforms\windows\PixCapWin
dotnet build -c Release -r win-arm64
dotnet run   -c Release -r win-arm64

# Everything, both architectures, plus installers
cd platforms\windows
.\build.ps1 -Installer
```

**"Access is denied" when cargo rebuilds the DLL** means something has it
mapped. Quit PixCap, and close any PowerShell window that ran
`test-render.ps1` — P/Invoke keeps a DLL loaded for the life of the process.

**Do not run the app elevated.** `FileSavePicker` returns null without ever
showing a dialog in an elevated process, so "Save as" appears to do nothing at
all. Nothing is wrong with the app; it is a shell restriction. Launching from
an elevated terminal is the usual way to trip over this — `explorer.exe
<path-to-exe>` starts it back at the normal integrity level.

**Renderer without the app:** `.\test-render.ps1 -Annotate` calls the render
FFI directly. Useful for isolating a rendering problem from a UI problem.

**Timing the renderer:** the editor reports how long each preview took in the
status bar, so a regression is visible while using the app. For numbers without
the UI:

```powershell
cargo run --release --target aarch64-pc-windows-msvc --example render-bench -- <image.png> [scale] [out.png]
```

It times a plain canvas, a shadow, grain, and both, so a change can be
attributed. Pass `WxH` instead of a path for a synthetic capture of that size —
`3840x2160` is the case that used to take a minute.

**Rust tests:** `cargo test` — 41 in the core. All pass on Windows except
`document::tests::derives_sidecar_paths`, which asserts
`sidecar_path("/a/b/shot.png") == "/a/b/shot.pixcap.json"`; on Windows
`std::path` joins with a backslash. Pre-existing, and in a function macOS
depends on, so it was left alone.

---

## Closed bugs

All four were fixed and checked by using the app, not by compiling it. Where
the original diagnosis turned out to be wrong, the wrong version is kept below,
because guessing from the wrong machine is exactly what this file exists to
stop.

### 1. No "Capture Area" — only window and screen — **done**

There is now a **Capture area** card on the Capture page.
`Capture\RegionSelectionOverlay.cs` puts a borderless, always-on-top surface on
every display: dimmed, with a drag rectangle, a `W x H px` readout, and Escape
or right-click to cancel. The selection is cropped out with
`ScreenCaptureEngine.CropAsync`, then named, saved, and indexed as mode
`region` like any other capture.

Two things differ from the plan, both discovered by running it:

- **The displays are captured first, and the overlay shows that frozen image.**
  The plan was the macOS shape — a live transparent overlay excluded from the
  shot. Inverting it removes the exclusion problem entirely, and the pixels
  selected are the pixels that were on screen at the moment of the click rather
  than one repaint later. The main window is hidden before the capture, so
  PixCap is not frozen into the middle of the shot.
- **`GraphicsCaptureItem.TryCreateFromDisplayId` cannot be used.** It is the
  modern API and it compiles, but naming a display rather than picking one
  counts as *programmatic* capture, and Windows answers `DeniedByUser` for an
  app with no package identity — which this one deliberately is, so it can run
  from a folder. `IGraphicsCaptureItemInterop::CreateForMonitor` carries no
  such gate. It is called through its vtable in `MonitorInterop`, so it does
  not depend on which COM interop mode the app is built with.
- **The overlay is Windows Forms, not WinUI 3.** The rest of the app is WinUI;
  this one screen is not. See the next section for why.

### The overlay's crosshair, and why it is not WinUI

Worth writing down, because the first version looked correct and was not.

The overlay is drawn over a screenshot that was taken a moment earlier, so the
pointer is usually standing perfectly still when it appears. WinUI 3 routes
pointer input through a content island and applies `ProtectedCursor` only when
a mouse message arrives — and a pointer that is not moving never produces one.
The overlay therefore came up showing the arrow inherited from the button that
had just been clicked, and only became a crosshair once the mouse moved.

Four attempts to force it from inside WinUI failed, each disproved by making
the app report its own state rather than by reasoning:

```
Force(32515) before SetCursor: ARROW
Force(32515) after SetCursor:  ARROW      <- SetCursor changed nothing at all
Force(32515) after nudge:      ARROW      <- +1/-1 coalesced into a net-zero move
```

`SetCursor` from the app does nothing; a synthetic move out and back in one
breath is coalesced away; deferring to `Loaded`, to `VisibilityChanged`, and to
a timer after it all changed nothing. A classic HWND owns `WM_SETCURSOR`
itself, so a Windows Forms overlay gets this right with `Cursor =
Cursors.Cross` and needs none of it.

Two things fall out of the move, both improvements. The form works in physical
pixels throughout (`AutoScaleMode.None`), so the selection needs no DIP
conversion at all; and it runs on its own STA thread with its own message loop,
so the two frameworks never pump the same queue.

Windows Forms is pulled in with a `FrameworkReference`, not with
`UseWindowsForms`: that property imports the WinFX targets, which treat every
`.xaml` in the project as WPF markup and fail on WinUI's.

### 2. Application icon missing — **done**

`<ApplicationIcon>` was enough. The icon shows in the title bar, the taskbar,
and Alt-Tab. No runtime `AppWindow.SetIcon` call is needed.

### 3. Changing the background takes about a minute — **done**

Real, and correctly diagnosed. Both hot spots were as described. Measured with
`--example render-bench`, best of two runs at 2x:

| Source | before | after |
|:--|--:|--:|
| 1612x920 window, shadow only | 2.59s | 0.34s |
| 1612x920 window, grain + shadow + PNG | 3.29s | 0.72s |
| 3840x2160 display, shadow only | 13.84s | 2.37s |
| 3840x2160 display, grain + shadow + PNG | 15.62s | 3.10s |

In the app, one preview of the 1612x920 capture went from **3576 ms to 161 ms**,
and changing the background preset now takes about **105 ms**. Turning shadow
and grain up to maximum costs 120 ms.

Three of the four suggested fixes were applied:

1. **The preview renders at display scale.** `MainWindow.PreviewScale` asks the
   core for the canvas size, fits it to the space available, and multiplies by
   the rasterization scale, so one image pixel lands on one device pixel. On a
   4K capture that alone takes the render from 15.6s to about 0.2s, because the
   shadow's blur radius shrinks with the scale as well as the pixel count.
   "Save as" re-renders at 2x rather than copying the preview.
2. **Grain is written into the pixmap buffer** by `draw_grain`. Blocks are
   still 2 canvas points except where that would land inside a single pixel:
   below about half scale the block size is raised so a preview does not end up
   grainier than the export it is previewing.
3. **`box_blur` walks a running total** and only visits the frame's bounding
   box grown by the blur's reach. Cost per pixel no longer depends on the
   radius, and the six full-pixmap `Vec` copies are gone.

The fourth — caching the background layer — was not needed and was left
undone. At 100-160 ms a full redraw is comfortably interactive, and a cache
would have to be invalidated on nine different settings.

Dots, Grid, Linen and Paper were left on `fill_rect`: at a few thousand calls
each they cost single-digit milliseconds, unlike grain's 448,000.

### 4. Annotations appear, then vanish — **done, but not for the stated reason**

**The diagnosis above was wrong.** It was not a consequence of bug 3, and
annotations were not merely invisible for the length of a render — they were
being *discarded*, permanently. Fixing bug 3 did not fix this.

The real cause is in `AnnotationCanvas.OnPointerReleased`:

```csharp
ReleasePointerCapture(e.Pointer);   // raises PointerCaptureLost synchronously
_dragging = false;
switch (Tool) { ... if (_draft is not null) { _store.Add(_draft); } ... }
```

`PointerCaptureLost` is wired to `EndDrag()`, which sets `_draft = null`. WinUI
raises it **synchronously** from inside `ReleasePointerCapture`, so by the time
the `switch` reads `_draft` it is always null and nothing is ever committed.
Only Counter and Text survived, because they build their item from the release
position instead of the draft. Every tool drawn by dragging — rectangle,
ellipse, line, arrow, freehand, highlight, redaction, spotlight, blur, crop —
silently did nothing.

Traced by logging the pointer handlers to a file and dragging the app:

```
17:37:26.558 released dragging=True draft=set meaningful=True
17:37:26.559 capture lost
```

The fix takes the draft into a local and settles the drag state before
releasing capture. The same ordering is used in the region overlay, which has
the same shape.

The durable overlay fix suggested above was also worth doing and is in place:
`AnnotationCanvas.PreviewIsStale` keeps committed annotations drawn in the
overlay from the moment a render starts until the new preview is on screen.
Checked frame by frame at 35 ms intervals — the rectangle is present in every
frame from 1 ms after release onwards, with no gap at the handover.

---

## Also missing on Windows

Not bugs — never implemented. macOS has all of these.

| Feature | macOS | Windows |
|:--|:--:|:--:|
| Region capture | yes | yes |
| Screen recording (MP4/GIF) | yes | no |
| OCR / text extraction | yes | no |
| Pin to screen | yes | no |
| Scrolling capture | yes | core is ready, no UI |
| Quick Access overlay | yes | no |
| Global hotkeys | yes | area capture only |
| Preferences window | yes | partial (a Settings page) |

Region capture selects within one display; a drag cannot span two. macOS
behaves the same way, so this is a match rather than a gap.

---

## Other changes made at the same time

- **The annotation palette shows icons, not words.** It previously used labels
  because Segoe Fluent code points could not be checked from macOS. They can be
  checked here, and were: every candidate was rendered to a PNG and looked at
  before being chosen. See `AnnotationToolExtensions.Glyph`. The code points are
  written as `\uXXXX` escapes rather than pasted characters, because a
  private-use glyph is invisible in a diff and in most editors. `Label()`
  remains, as the tooltip and the accessible name.
- **The status bar reports how long a render took.** Cheap, and it means a
  performance regression is noticed while using the app rather than in a
  bug report.
- **Opening Beautify renders the current capture.** `UpdateBeautifyTarget`
  pointed the page at a capture but never asked for a preview, so the panel
  stayed empty until some unrelated setting was nudged — and once an earlier
  capture had been rendered, the *previous* screenshot stayed on screen under
  the new one's name. Switching target now also clears the annotations and the
  crop, which were positioned against the capture being replaced.
- **A global shortcut starts an area capture.** `Win+Alt+S` by default,
  changeable in Settings and remembered in
  `%LOCALAPPDATA%\PixCap\settings.json`. `Win+Shift+S` belongs to the Snipping
  Tool and cannot be claimed. `RegisterHotKey` needs a window procedure, which
  WinUI 3 does not hand out; the listener is a Windows Forms `NativeWindow`,
  which is available now that the region overlay uses Windows Forms anyway, and
  WinUI's message loop dispatches to it because both are on the same thread.
  Reading the modifiers from the key event does not work for `Win` — the shell
  takes it — so they are read from the keyboard state instead.

- **Any annotation colour, not six.** The six presets remain as one-click
  swatches; the button under them opens a colour wheel with a brightness slider
  and hex entry. Choosing a colour also recolours the current selection, which
  is the point: a colour that only applied to the next shape would mean
  deleting and redrawing whatever is already on the canvas. The choice is
  remembered in `settings.json`.

  **The wheel is drawn by `Views/ColorWheel.cs`, not by WinUI.** WinUI's
  `ColorPicker` was the obvious choice and its spectrum renders as a solid
  black square here — explicit sizing, `ColorSpectrumShape="Ring"` and hosting
  outside a flyout all changed nothing, while the same control's sliders, hex
  box and RGB fields worked. The failure is inside `ColorSpectrum`'s own
  surface, and a machine with no GPU is the likely cause: Direct3D already
  falls back to WARP here, which `ScreenCaptureEngine` has always had to allow
  for. The replacement fills a bitmap pixel by pixel and hands it to an
  `Image` — no composition surface, nothing to fall back from.
- **PixCap lives in the notification area.** The shortcut only fires while the
  process is running, so closing the window hides it by the clock instead of
  quitting, and the installer's login shortcut — checked by default — starts it
  with `--background`, straight into the tray. The menu offers Capture area,
  Open and Quit; Quit is there because an app that cannot be closed from where
  it lives is a process the user did not agree to. `NotifyIcon` again, since
  WinUI 3 has no notification-area API. On Windows 11 the icon lands in the
  overflow flyout until the user drags it out, which is Windows' behaviour for
  every new icon, not something the app chooses.
- **The preview measures its container, not itself.** `PreviewHost` is centred,
  so its `ActualWidth` is whatever is already inside it: asking it how much
  room there was answered with the previous render's size, and on the first
  render of a freshly shown page answered with nothing at all, which pinned the
  preview to the minimum scale. It now measures `PreviewArea` after forcing a
  layout pass.

Scrolling capture is the cheapest of these: the stitcher already works and is
exposed as `pixcap_stitch_scroll_frames`. It only needs a UI to collect frames.

---

## Conventions worth keeping

- **ASCII only in `.ps1` files.** Windows PowerShell 5.1 reads UTF-8 without a
  BOM as Windows-1252, where an em-dash's third byte becomes a smart quote that
  PowerShell treats as a string delimiter. This has already broken a build once.
- **No `--` inside XML comments.** It is invalid XML and MSBuild rejects the
  project file. This has also already broken a build once.
- `python3 scripts/validate-build-files.py` checks both. Python is not
  installed on this machine, so it has not been run here — the XAML and the
  project file were checked by building instead.
- **C# files keep a UTF-8 BOM** when they contain non-ASCII characters.
- Coordinates for annotations are **image-space points, top-left origin** —
  the same as macOS and the renderer. Never store screen coordinates.
- Ask the renderer for geometry (`pixcap_render_layout`) instead of
  recomputing canvas arithmetic in C#.
- **Release pointer capture last.** `ReleasePointerCapture` raises
  `PointerCaptureLost` synchronously, so any handler wired to it runs before
  the rest of the release handler. Settle the drag state and copy anything you
  still need into a local first. This cost the editor every drag-drawn
  annotation once already (bug 4).
- **Icon glyphs are chosen by looking at them.** Render the candidates and
  compare; a code point recalled from memory is a guess, and the wrong picture
  is worse than a word.
