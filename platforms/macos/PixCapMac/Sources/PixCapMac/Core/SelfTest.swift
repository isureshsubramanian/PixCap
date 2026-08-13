import Foundation
import AppKit

/// Headless verification of the pieces that do not need a window server:
/// the Rust bridge, the beautifier renderer, and the export path.
///
/// Run with `swift run PixCapMac --self-test`.
@available(macOS 14.0, *)
public enum SelfTest {
    public static func run() -> Bool {
        var failures: [String] = []

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("  ✓ \(name)")
            } else {
                print("  ✗ \(name)")
                failures.append(name)
            }
        }

        print("PixCap self-test")

        // 1. Shared preset catalogue crosses the FFI boundary intact.
        let presets = PixCapBridge.shared.backgroundPresets
        check("theme presets decode from Rust (\(presets.count) found)", presets.count >= 8)
        check("preset lookup by id", PixCapBridge.shared.preset(id: "amethyst")?.name == "Amethyst")

        var gradientStops = 0
        if let amethyst = PixCapBridge.shared.preset(id: "amethyst"),
           case .gradient(_, let stops) = amethyst.fill {
            gradientStops = stops.count
        }
        check("gradient stops decode (\(gradientStops))", gradientStops == 3)

        var isTransparent = false
        if let preset = PixCapBridge.shared.preset(id: "transparent"),
           case .transparent = preset.fill {
            isTransparent = true
        }
        check("unit enum variant decodes", isTransparent)

        // 2. Naming patterns resolve through the Rust core.
        let resolved = PixCapBridge.shared.resolveFilename(
            pattern: "{app}_{mode}_{width}x{height}_{counter}",
            mode: "area",
            appName: "Safari",
            windowTitle: nil,
            width: 1920,
            height: 1080,
            counter: 7
        )
        check("filename pattern resolves (\(resolved))", resolved == "Safari_area_1920x1080_7")

        // 3. Layout maths.
        let source = sampleImage(size: CGSize(width: 400, height: 300))
        let config = BeautifyConfig(
            background: .preset(id: "amethyst"),
            padding: 40,
            cornerRadius: 16,
            shadowBlur: 24,
            frameStyle: .macOS,
            aspectRatio: .auto,
            frameTitle: "self-test"
        )
        let layout = BeautifierRenderer.layout(imageSize: source.size, config: config)
        check("canvas adds padding on both axes", layout.canvasSize.width == 480 && layout.canvasSize.height == 414)
        check("image sits below the window header", layout.imageRect.minY == layout.frameRect.minY + 34)

        var ratioConfig = config
        ratioConfig.aspectRatio = .sixteenNine
        let ratioLayout = BeautifierRenderer.layout(imageSize: source.size, config: ratioConfig)
        let achieved = ratioLayout.canvasSize.width / ratioLayout.canvasSize.height
        check("aspect ratio constraint applied (\(String(format: "%.3f", achieved)))", abs(achieved - 16.0 / 9.0) < 0.001)
        check("aspect ratio only grows the canvas", ratioLayout.canvasSize.width >= layout.canvasSize.width)

        // 4. Rendering, including annotations and a baked blur region.
        let annotations = [
            AnnotationItem(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 200, y: 160), colorHex: "#FF3366", strokeWidth: 4),
            AnnotationItem(tool: .arrow, start: CGPoint(x: 40, y: 240), end: CGPoint(x: 320, y: 90), colorHex: "#00E5FF", strokeWidth: 5),
            AnnotationItem(tool: .counter, start: CGPoint(x: 340, y: 240), end: CGPoint(x: 340, y: 240), colorHex: "#FFB300", strokeWidth: 3, number: 1),
            AnnotationItem(tool: .text, start: CGPoint(x: 30, y: 260), end: .zero, colorHex: "#FFFFFF", strokeWidth: 2, text: "PixCap", fontSize: 28),
            AnnotationItem(tool: .blur, start: CGPoint(x: 220, y: 180), end: CGPoint(x: 380, y: 280), colorHex: "#000000", strokeWidth: 1, blurStyle: .pixelate, blurIntensity: 24)
        ]

        guard let rendered = BeautifierRenderer.render(image: source, annotations: annotations, config: config, scale: 2.0) else {
            print("  ✗ renderer returned nil")
            print("FAILED")
            return false
        }
        check("rendered canvas matches layout size", rendered.size == layout.canvasSize)

        guard let data = ImageExporter.data(from: rendered, format: .png) else {
            print("  ✗ PNG encoding failed")
            print("FAILED")
            return false
        }
        check("PNG encodes at 2x pixel size", NSBitmapImageRep(data: data)?.pixelsWide == Int(layout.canvasSize.width * 2))

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixcap-selftest.png")
        do {
            try data.write(to: outputURL)
            print("  · wrote \(outputURL.path)")
        } catch {
            check("write render to disk", false)
        }

        // Transparent preset must keep its alpha channel.
        var alphaConfig = config
        alphaConfig.background = .preset(id: "transparent")
        alphaConfig.frameStyle = .none
        if let alphaRender = BeautifierRenderer.render(image: source, config: alphaConfig, scale: 1.0),
           let alphaData = ImageExporter.data(from: alphaRender, format: .png),
           let rep = NSBitmapImageRep(data: alphaData) {
            let corner = rep.colorAt(x: 2, y: 2)
            check("transparent canvas keeps alpha", (corner?.alphaComponent ?? 1) < 0.01)
        } else {
            check("transparent canvas renders", false)
        }

        // 5. History round-trip through SQLite.
        let store = HistoryStore.shared
        let marker = "selftest-\(UUID().uuidString)"
        let inserted = store.insert(ScreenshotRecord(
            id: 0,
            filepath: outputURL.path,
            thumbnail_path: nil,
            captured_at: ISO8601DateFormatter().string(from: Date()),
            capture_mode: "self-test",
            width: Int64(rendered.size.width),
            height: Int64(rendered.size.height),
            ocr_text: marker,
            tags: nil,
            is_favorited: false
        ))
        check("history insert returns a row id", inserted > 0)
        check("history search finds the row", store.search(marker).count == 1)
        store.delete(id: inserted)
        check("history delete removes the row", store.search(marker).isEmpty)

        // 6. Hotkey bindings serialise and describe themselves.
        let defaultBinding = HotkeyAction.captureArea.defaultBinding
        check("default hotkey is a valid global shortcut", defaultBinding.isValid)
        check("hotkey renders modifiers (\(defaultBinding.displayString))", defaultBinding.displayString.contains("⌥"))

        // 7. Colour helpers used by annotation defaults.
        check("hex parses to colour", NSColor(hex: "#FF3366") != nil)
        check("colour round-trips to hex", NSColor(hex: "#FF3366")?.hexString == "#FF3366")
        check("malformed hex rejected", NSColor(hex: "#ZZZ") == nil)

        runPhase2Checks(check)

        print(failures.isEmpty ? "PASSED" : "FAILED: \(failures.joined(separator: ", "))")
        return failures.isEmpty
    }

    /// A deterministic test image with enough detail to show blur and annotations.
    static func sampleImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(hex: "#132033")?.setFill()
        NSRect(origin: .zero, size: size).fill()

        for row in 0..<Int(size.height / 20) {
            for column in 0..<Int(size.width / 20) {
                if (row + column) % 2 == 0 {
                    NSColor(hex: "#1E3A5F")?.setFill()
                    NSRect(x: CGFloat(column) * 20, y: CGFloat(row) * 20, width: 20, height: 20).fill()
                }
            }
        }

        ("api_key=sk-live-secret" as NSString).draw(
            at: NSPoint(x: 30, y: 60),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                .foregroundColor: NSColor.white
            ]
        )

        image.unlockFocus()
        return image
    }
}
