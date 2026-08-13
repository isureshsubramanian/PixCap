# PixCap

Capture, annotate, and beautify screenshots on macOS and Windows.

Two native apps sit on one shared Rust core. Nothing leaves the machine —
there is no account, no telemetry, and no server to upload to.

---

## Layout

```
crates/
  pixcap-core     rendering, scroll stitching, redaction, OCR index, history
  pixcap-ffi      C ABI, consumed by Swift on macOS and C# on Windows
  pixcap-ipc      local transport — Unix socket on macOS, named pipe on Windows
  pixcap-cli      headless rendering
platforms/
  macos           Swift + SwiftUI/AppKit, ScreenCaptureKit, Core Graphics
  windows         C# on .NET 8, WinUI 3, Windows.Graphics.Capture
extensions/
  vscode          VS Code extension (TypeScript)
  jetbrains       JetBrains plugin (Kotlin)
website/          landing page for pixcap.app
```

## Two renderers, on purpose

macOS draws through Core Graphics; Windows and the CLI draw through the
`tiny-skia` renderer in `pixcap-core`. That is a deliberate choice rather than
duplicated effort — each app renders with the framework native to its platform,
so each one feels like it belongs there.

What keeps them in agreement is the shared `AnnotationDocument` schema in
`pixcap-core`. Both renderers read the same field definitions, so the same
document produces the same layout. The contract lives in the data, not in
shared drawing code.

Everything else is shared outright: background presets, file naming, the
history database, syntax highlighting, and redaction all run in Rust and are
called over the same C ABI from both platforms.

## Building

Prerequisites: Rust 1.85+. Then Xcode Command Line Tools and Swift 6+ for
macOS, or Visual Studio 2022 with the Windows App SDK for Windows.

```bash
cargo build --workspace
cargo test --workspace     # 48 tests
```

Platform apps:

```bash
# macOS — produces PixCap.app
./platforms/macos/PixCapMac/scripts/make-app.sh

# Windows — add -Installer for setup.exe
./platforms/windows/build.ps1
```

`platforms/windows/README.md` covers the Windows build in more detail,
including what is and is not implemented there yet.

## Licence

Apache License 2.0 — see [LICENSE](./LICENSE).
