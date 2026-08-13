# PixCap for Windows 11 — build steps

The Windows shell links the **same Rust core** as the macOS app. Capture is
platform-native (`Windows.Graphics.Capture`); file naming, the history
database, background presets, and syntax highlighting all come from
`pixcap_ffi.dll`, so those behave identically on both platforms.

> **Status: compiles; not yet run.** Authored on macOS, so the C# has been
> fixed reactively as build errors came back. It builds for ARM64 and x64, but
> nothing has exercised the capture path at runtime yet.

---

## 1. Prerequisites (inside the Windows 11 VM)

Install in this order:

1. **Visual Studio 2022** (Community is fine) — <https://visualstudio.microsoft.com/downloads/>
   During install, tick these workloads:
   - **.NET desktop development**
   - **Desktop development with C++** (needed by the Rust MSVC toolchain)
   - Under *Individual components*: **Windows 11 SDK (10.0.22621 or newer)**

2. **Rust** — <https://rustup.rs>
   ```powershell
   winget install Rustlang.Rustup
   rustup default stable-msvc
   ```

3. **Windows App SDK** — restored automatically by NuGet, no separate install.

Verify:
```powershell
dotnet --version     # 8.0 or newer
cargo --version
```

## 2. Get the source into the VM

Either share the folder from macOS through Parallels, or clone it:

```powershell
git clone https://github.com/isureshsubramanian/PixCap.git
cd PixCap
```

Working over a Parallels shared folder is convenient but slower to build, and
`cargo` sometimes struggles with file locking there. A local clone is more
reliable.

## 3. Build the shared Rust core

```powershell
cargo build --release
```

The whole workspace is verified to compile for Windows: it is type-checked
against the `x86_64-pc-windows-gnu` target on every change. Your build uses the
MSVC toolchain rather than GNU, so linker-level differences are still possible,
but nothing platform-specific should fail to compile.

This produces `target\release\pixcap_ffi.dll`. The `.csproj` copies that DLL
next to the executable automatically.

If the linker complains about `link.exe`, the C++ workload from step 1 is
missing — install it and reopen the terminal.

> **"Access is denied" when cargo rebuilds the DLL?** Something has
> `pixcap_ffi.dll` mapped. Quit PixCap if it is running, and close any
> PowerShell window that has run `test-render.ps1` - P/Invoke keeps the DLL
> loaded for the life of that process, even after the script finishes. The
> harness now loads a copy from temp to avoid this, but a shell from before
> that change still holds the original.

## 4. Build for both architectures

One script builds the Rust core and the app for each architecture:

```powershell
cd platforms\windows
.\build.ps1                       # both ARM64 and x64
.\build.ps1 -Architecture x64     # just one
```

It installs the Rust target, builds `pixcap_ffi.dll` for that architecture,
publishes the app against it, and checks the DLL actually landed in the output.

Output goes to:

```
PixCapWin\bin\Release\net8.0-windows10.0.22621.0\win-arm64\publish\
PixCapWin\bin\Release\net8.0-windows10.0.22621.0\win-x64\publish\
```

### Producing a setup.exe

```powershell
winget install JRSoftware.InnoSetup     # once
.\build.ps1 -Installer
```

Installers land in `dist\`:

```
dist\PixCap-2.0.0-arm64-setup.exe
dist\PixCap-2.0.0-x64-setup.exe
```

They install per-user by default, so no UAC prompt, and offer optional desktop
and startup shortcuts. The app is published self-contained, so the installer
carries the .NET runtime, the Windows App SDK, and `pixcap_ffi.dll` - nothing
to install first. Setup refuses to run on anything older than Windows 10 1903,
which is where `Windows.Graphics.Capture` arrived.

**These installers are unsigned.** SmartScreen will show "Windows protected
your PC" and require *More info -> Run anyway* on any machine that has not seen
the binary before. Silencing that needs an Authenticode code-signing
certificate (an OV certificate builds reputation over time; an EV certificate
is trusted immediately). That is a separate purchase from the Apple Developer
account, which does not apply on Windows.

### Or by hand

```powershell
rustup target add aarch64-pc-windows-msvc
cargo build --release --target aarch64-pc-windows-msvc

cd platforms\windows\PixCapWin
dotnet build -c Release -r win-arm64
dotnet run   -c Release -r win-arm64
```

Swap `aarch64-pc-windows-msvc` / `win-arm64` for `x86_64-pc-windows-msvc` /
`win-x64` to build the other one. The project defaults to ARM64 when no `-r` is
given, since a Parallels VM on Apple Silicon is ARM64.

The build picks the Rust DLL matching the `RuntimeIdentifier` automatically,
and **fails with a clear message if it is missing** rather than letting you
discover it as a `BadImageFormatException` at the first P/Invoke.

Which architecture is this VM?

```powershell
echo $env:PROCESSOR_ARCHITECTURE     # ARM64 or AMD64
```

Note that an ARM64 Windows VM can run x64 builds under emulation, but the app
and the DLL must still agree with each other.

On launch the window should show:

```
Shared core loaded · 10 background presets · 66 languages
```

That line is the proof the FFI works: those numbers come from Rust, not C#.

---

## What works and what does not

| Area | State |
|:--|:--|
| Shared core over FFI (presets, naming, history, syntax) | Written, follows the same C ABI the Mac app uses |
| Screen capture via `GraphicsCapturePicker` | Written |
| History browsing and full-text search | Written |
| Beautification (background, padding, shadow, frame) | Written — renders through the Rust core, see below |
| Annotation editor | Written |
| Region capture, global shortcut, tray icon | Written |
| Recording, OCR, pins, scrolling capture | Not implemented |

### Where beautification is rendered

On macOS the renderer is written in Swift with Core Graphics, so there was
nothing for Windows to call. Two options were open:

1. **Re-implement it in C# with Win2D** — fast to write, but it leaves two
   renderers to drift apart, and the drift is silent.
2. **Put a renderer in the Rust core** and have Windows and the CLI call it.
   More work up front, and it also gives the CLI real image rendering.

Option 2 is what shipped: `crates/pixcap-core/src/render/`, built on
`tiny-skia`. macOS still draws through Core Graphics, so each app renders with
the framework native to its platform. What keeps the two in agreement is the
shared `AnnotationDocument` schema — the same document produces the same
layout on both, because both read the same field definitions.

---

## Likely first-build errors

Since this has never been compiled, budget time for these:

- **`Direct3D11Helper`** — the D3D device interop is the least certain part of
  the capture path. If `CreateDevice()` throws, the usual fix is to add the
  `Win2D.uwp` or `SharpDX`-style helper rather than hand-rolling the interop.
- **`WinRT.Interop.InitializeWithWindow`** — namespace moved between Windows
  App SDK versions; if unresolved, try `Microsoft.UI.Xaml.Window` extensions or
  update the SDK package version in the `.csproj`.
- **`ApiInformation` wrapper** — the shim at the bottom of
  `ScreenCaptureEngine.cs` may collide with the WinRT type of the same name;
  fully qualify or delete the shim if so.
- **DLL not found at runtime** — confirm `pixcap_ffi.dll` sits next to
  `PixCapWin.exe` in `bin\Release\net8.0-windows10.0.19041.0\win-x64\`.
  Step 3 must run before step 4.
- **Architecture mismatch** — an ARM64 Windows VM on Apple Silicon needs
  `cargo build --release --target aarch64-pc-windows-msvc` and
  `dotnet build -r win-arm64`. Mixing x64 and ARM64 gives a
  `BadImageFormatException` when P/Invoke loads the DLL.

Send me whatever errors come back and I will fix them.
