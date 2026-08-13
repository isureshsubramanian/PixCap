# PixCap - High-Performance Cross-Platform Screen Snapshot & Code Beautifier

PixCap is a next-generation screen snapshot and code snippet engine designed natively for **macOS (Apple Silicon ARM64)** and **Windows 11 (x64 / ARM64)**.

---

## 🏗️ Architecture Overview (Option B)

PixCap uses a modular hybrid architecture:
- **Rust Core Workspace (`crates/`):**
  - `pixcap-core`: 2D Skia canvas layout, mesh gradient theme engine, Syntect/Tree-Sitter syntax parser, transparent PNG/SVG export, smart data redaction.
  - `pixcap-ipc`: Local IPC server (Unix Domain Sockets on macOS, Named Pipes on Windows 11).
  - `pixcap-ffi`: C-ABI shared library bindings for Swift (macOS) and C++ (Windows 11).
- **Native OS Capture Apps (`platforms/`):**
  - macOS: Swift / AppKit / ScreenCaptureKit native M3 Apple Silicon app shell.
  - Windows 11: C++/WinRT / WinUI 3 `Windows.Graphics.Capture` engine.
- **IDE Extensions (`extensions/`):**
  - `extensions/vscode`: VS Code Extension (TypeScript).
  - `extensions/jetbrains`: JetBrains Plugin (Kotlin).

---

## 🚀 Quick Start (Development)

### Prerequisites
- **macOS:** Xcode Command Line Tools, Swift 6+, Rust 1.85+, Node.js v20+
- **Windows 11:** Visual Studio 2022 (C++ / WinRT), Rust 1.85+

### Build & Run Tests
```bash
# Build Rust Workspace Core
cargo build --workspace

# Run Unit Tests
cargo test --workspace
```

---

## 📄 Architectural Decision Record
Read the full decision analysis in [`ADR-001.md`](./ADR-001.md) or [`docs/ADR-001.md`](./docs/ADR-001.md).
