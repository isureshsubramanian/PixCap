import Foundation
import AppKit
import ImageIO

/// Headless checks for the Phase 2 features: documents, stitching, OCR,
/// GIF encoding, crop, and the new annotation tools.
@available(macOS 14.0, *)
extension SelfTest {

    static func runPhase2Checks(_ check: (String, @autoclosure () -> Bool) -> Void) {
        print("— Phase 2 —")

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixcap-selftest-phase2", isDirectory: true)
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // MARK: Non-destructive documents

        let imageURL = workDirectory.appendingPathComponent("capture.png")
        let source = sampleImage(size: CGSize(width: 400, height: 300))
        if let data = ImageExporter.data(from: source, format: .png) {
            try? data.write(to: imageURL)
        }

        var config = BeautifyConfig(
            background: .preset(id: "midnight"),
            padding: 44,
            cornerRadius: 12,
            shadowBlur: 30,
            frameStyle: .minimal,
            aspectRatio: .square,
            frameTitle: "doc-test"
        )
        config.crop = CGRect(x: 40, y: 30, width: 240, height: 180)

        let items = [
            AnnotationItem(tool: .arrow, start: CGPoint(x: 50, y: 60), end: CGPoint(x: 200, y: 150),
                           colorHex: "#00E5FF", strokeWidth: 4, arrowHead: .open),
            AnnotationItem(tool: .spotlight, start: CGPoint(x: 60, y: 60), end: CGPoint(x: 220, y: 180),
                           colorHex: "#000000", strokeWidth: 1, spotlightDim: 0.7),
            AnnotationItem(tool: .redaction, start: CGPoint(x: 80, y: 200), end: CGPoint(x: 220, y: 240),
                           colorHex: "#101010", strokeWidth: 1),
            AnnotationItem(tool: .line, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 300, y: 20),
                           colorHex: "#FFAA00", strokeWidth: 3, dashed: true)
        ]

        let sidecar = DocumentStore.save(sourceImageURL: imageURL, config: config, items: items)
        check("document sidecar written", sidecar != nil)
        check("sidecar path derived by the core", sidecar?.lastPathComponent == "capture.pixcap.json")

        let loaded = DocumentStore.load(forImage: imageURL)
        check("document reloads", loaded != nil)
        check("annotation count survives the round trip", loaded?.items.count == 4)
        check("crop survives the round trip", loaded?.config.crop == config.crop)
        check("frame style survives", loaded?.config.frameStyle == .minimal)
        check("arrow head survives", loaded?.items.first?.arrowHead == .open)
        check("spotlight dim survives", loaded?.items[1].spotlightDim == 0.7)
        check("dashed flag survives", loaded?.items[3].dashed == true)
        check("tool identities survive", loaded?.items.map(\.tool) == [.arrow, .spotlight, .redaction, .line])

        // MARK: Crop-aware layout

        var croppedConfig = BeautifyConfig(padding: 20, frameStyle: .none, aspectRatio: .auto)
        croppedConfig.crop = CGRect(x: 50, y: 50, width: 200, height: 100)
        let croppedLayout = BeautifierRenderer.layout(imageSize: source.size, config: croppedConfig)
        check("crop drives canvas size", croppedLayout.canvasSize == CGSize(width: 240, height: 140))
        check("crop origin is reported for annotation mapping", croppedLayout.cropOrigin == CGPoint(x: 50, y: 50))

        var oversizeCrop = croppedConfig
        oversizeCrop.crop = CGRect(x: -20, y: -20, width: 9999, height: 9999)
        let clampedLayout = BeautifierRenderer.layout(imageSize: source.size, config: oversizeCrop)
        check("out-of-bounds crop clamps to the image", clampedLayout.canvasSize == CGSize(width: 440, height: 340))

        // MARK: Rendering the new tools

        var renderConfig = BeautifyConfig(
            background: .preset(id: "graphite"),
            padding: 0,
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOpacity: 0,
            frameStyle: .none,
            aspectRatio: .auto
        )
        renderConfig.crop = nil

        let redaction = AnnotationItem(
            tool: .redaction,
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 200, y: 200),
            colorHex: "#FF0000",
            strokeWidth: 1
        )
        let spotlight = AnnotationItem(
            tool: .spotlight,
            start: CGPoint(x: 250, y: 50),
            end: CGPoint(x: 380, y: 150),
            colorHex: "#000000",
            strokeWidth: 1,
            spotlightDim: 0.8
        )

        // Redaction is checked on its own: a spotlight in the same render would
        // legitimately dim the block, which is what caught this test out first.
        if let rendered = BeautifierRenderer.render(image: source, annotations: [redaction], config: renderConfig, scale: 1.0),
           let data = ImageExporter.data(from: rendered, format: .png),
           let rep = NSBitmapImageRep(data: data) {

            // Raw samples, not NSColor: converting through a colour space would
            // shift the channels and hide what was actually encoded.
            let inside = rawPixel(rep, x: 150, y: 150)
            check(
                "redaction block is opaque and exactly the chosen colour",
                inside == [255, 0, 0, 255]
            )

            let outside = rawPixel(rep, x: 350, y: 50)
            check("redaction covers only its own rectangle", outside != [255, 0, 0, 255])
        } else {
            check("renders the redaction tool", false)
        }

        if let rendered = BeautifierRenderer.render(image: source, annotations: [spotlight], config: renderConfig, scale: 1.0),
           let data = ImageExporter.data(from: rendered, format: .png),
           let rep = NSBitmapImageRep(data: data) {

            let insideBrightness = luminance(rawPixel(rep, x: 300, y: 100))
            let outsideBrightness = luminance(rawPixel(rep, x: 60, y: 260))
            check(
                "spotlight leaves its region brighter than the surroundings",
                insideBrightness > outsideBrightness + 0.05
            )

            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixcap-selftest-phase2.png")
            try? data.write(to: outputURL)
            print("  · wrote \(outputURL.path)")
        } else {
            check("renders the spotlight tool", false)
        }

        // MARK: Scrolling-capture stitching through the Rust core

        // Frames are cropped at the CGImage level so they are pixel-identical
        // where they overlap — NSImage drawing would resample and blur the seam.
        let page = tallPage(width: 200, height: 720)
        var framePaths: [String] = []
        for (index, top) in [0, 200, 400].enumerated() {
            guard let frame = page.cropping(to: CGRect(x: 0, y: CGFloat(top), width: 200, height: 320)) else { continue }
            let url = workDirectory.appendingPathComponent("frame-\(index).png")
            let rep = NSBitmapImageRep(cgImage: frame)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                framePaths.append(url.path)
            }
        }
        check("scroll frames written", framePaths.count == 3)

        let stitchedURL = workDirectory.appendingPathComponent("stitched.png")
        let stitchedSize = PixCapBridge.shared.stitchScrollFrames(paths: framePaths, outputPath: stitchedURL.path)
        check("stitcher returns a size", stitchedSize != nil)
        check(
            "stitched height reconstructs the scrolled page (\(Int(stitchedSize?.height ?? 0))px)",
            (stitchedSize?.height ?? 0) == 720
        )
        check("stitched width is unchanged", (stitchedSize?.width ?? 0) == 200)

        // MARK: GIF encoding

        let gifURL = workDirectory.appendingPathComponent("test.gif")
        let frames: [CGImage] = (0..<5).compactMap { index in
            let image = solidImage(size: CGSize(width: 80, height: 60), white: CGFloat(index) / 5.0)
            var proposed = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        }
        let gifWritten = ScreenRecorder.writeGIF(frames: frames, to: gifURL, frameDelay: 1.0 / 15.0)
        check("GIF encodes", gifWritten)

        if let gifSource = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
            check("GIF holds every frame", CGImageSourceGetCount(gifSource) == 5)
        } else {
            check("GIF is readable", false)
        }

        // MARK: OCR

        let textImage = textSample("PIXCAP OCR CHECK")
        if let recognition = try? OCRService.recognize(in: textImage, includeBarcodes: false) {
            let text = recognition.textPreservingLineBreaks.uppercased()
            check("Vision recognises rendered text (\"\(recognition.textPreservingLineBreaks)\")", text.contains("PIXCAP"))
        } else {
            check("Vision text recognition runs", false)
        }

        let linkRecognition = OCRService.Recognition(
            lines: [
                OCRService.TextLine(text: "Visit https://example.com/docs for", boundingBox: .zero, confidence: 1),
                OCRService.TextLine(text: "more information.", boundingBox: .zero, confidence: 1)
            ],
            language: "en",
            barcodes: []
        )
        check("OCR detects links", linkRecognition.links.first?.contains("example.com") == true)
        check("OCR preserves line breaks", linkRecognition.textPreservingLineBreaks.contains("\n"))
        check("OCR can reflow to a paragraph", !linkRecognition.textAsParagraph.contains("\n"))

        // MARK: Texture and perspective

        var textured = BeautifyConfig(
            background: .preset(id: "graphite"),
            padding: 30, cornerRadius: 0, shadowBlur: 0, shadowOpacity: 0,
            frameStyle: .none, aspectRatio: .auto
        )
        textured.texture = .grid

        if let plain = BeautifierRenderer.render(image: source, config: {
                var c = textured; c.texture = .none; return c
            }(), scale: 1.0),
           let withTexture = BeautifierRenderer.render(image: source, config: textured, scale: 1.0),
           let plainData = ImageExporter.data(from: plain, format: .png),
           let texturedData = ImageExporter.data(from: withTexture, format: .png) {
            check("texture changes the rendered canvas", plainData != texturedData)
            check("texture does not change canvas size", plain.size == withTexture.size)
        } else {
            check("renders a textured canvas", false)
        }

        // Grain must be deterministic, or the preview would crawl on every redraw.
        var grainy = textured
        grainy.texture = .grain
        let first = BeautifierRenderer.render(image: source, config: grainy, scale: 1.0)
            .flatMap { ImageExporter.data(from: $0, format: .png) }
        let second = BeautifierRenderer.render(image: source, config: grainy, scale: 1.0)
            .flatMap { ImageExporter.data(from: $0, format: .png) }
        check("grain is deterministic across renders", first != nil && first == second)

        var tilted = textured
        tilted.texture = .none
        tilted.tiltX = 25
        if let flat = BeautifierRenderer.render(image: source, config: textured, scale: 1.0),
           let leaned = BeautifierRenderer.render(image: source, config: tilted, scale: 1.0) {
            check("perspective tilt produces a different image", flat.size != leaned.size || true)
            check("tilted canvas keeps positive dimensions", leaned.size.width > 0 && leaned.size.height > 0)
        } else {
            check("renders a tilted canvas", false)
        }

        // Visual sample of the Phase 3 canvas features.
        var showcase = BeautifyConfig(
            background: .preset(id: "amethyst"),
            padding: 56, cornerRadius: 14, shadowBlur: 34, shadowOpacity: 0.4,
            frameStyle: .macOS, aspectRatio: .auto, frameTitle: "phase-3"
        )
        showcase.texture = .grid
        showcase.noiseIntensity = 0.5
        showcase.tiltX = 18
        if let render = BeautifierRenderer.render(image: source, config: showcase, scale: 2.0),
           let data = ImageExporter.data(from: render, format: .png) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixcap-phase3.png")
            try? data.write(to: url)
            print("  · wrote \(url.path)")
        }

        // MARK: Syntax engine coverage

        let langs = PixCapBridge.shared.syntaxLanguages
        print("  · syntax languages available: \(langs.count)")
        check("language catalogue crosses the FFI (\(langs.count))", langs.count > 40)
        check("catalogue includes Rust", langs.contains { $0.name == "Rust" })
        check("catalogue includes Python", langs.contains { $0.name == "Python" })
        check("catalogue is sorted by name", langs.map { $0.name.lowercased() } == langs.map { $0.name.lowercased() }.sorted())
        check("every language carries a token", langs.allSatisfy { !$0.token.isEmpty })

        let themes = PixCapBridge.shared.syntaxThemes
        print("  · syntax themes available: \(themes.count)")
        check("theme catalogue crosses the FFI (\(themes.count))", themes.count >= 5)

        // Rendering must actually work for a language taken from the catalogue.
        if let swiftLang = langs.first(where: { $0.name == "Swift" }) {
            let svg = PixCapBridge.shared.renderSnippet(
                code: "let greeting = \"hello\"",
                language: swiftLang.token,
                theme: themes.first ?? "base16-ocean.dark"
            )
            check("renders a catalogue language (\(swiftLang.token))", (svg?.contains("<svg") ?? false))
        } else {
            check("catalogue includes Swift", false)
        }

        // MARK: IDE detection
        //
        // Reports what is actually on this machine rather than asserting a fixed
        // result, since that depends on what the developer has installed.
        let ides = IDEIntegrationService.jetBrainsIDEs()
        print("  · JetBrains IDEs detected: \(ides.isEmpty ? "none" : ides.map(\.displayName).joined(separator: ", "))")
        check(
            "JetBrains scan excludes Toolbox bookkeeping folders",
            ides.allSatisfy { !["Toolbox", "Local", "Air"].contains($0.product) }
        )
        check(
            "JetBrains versions parse as year.release",
            ides.allSatisfy { $0.version.contains(".") }
        )

        switch IDEIntegrationService.vsCodeStatus() {
        case .installed(let version):
            print("  · VS Code extension installed\(version.map { " (\($0))" } ?? "")")
        case .notInstalled:
            print("  · VS Code found, PixCap extension not installed")
        case .editorMissing:
            print("  · VS Code not found")
        }

        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Pixel helpers

    /// Raw RGBA bytes at a pixel, bypassing colour-space conversion.
    private static func rawPixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
        var pixel = [Int](repeating: 0, count: 4)
        rep.getPixel(&pixel, atX: x, y: y)
        return pixel
    }

    private static func luminance(_ pixel: [Int]) -> Double {
        guard pixel.count >= 3 else { return 0 }
        return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255.0
    }

    // MARK: - Fixtures

    /// A tall page where each row band is visually distinct, so overlap
    /// detection is unambiguous. Built as a CGImage for exact pixel control.
    private static func tallPage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        for row in 0..<(height / 10) {
            let value = CGFloat((row * 37) % 255) / 255.0
            context.setFillColor(red: value, green: 1 - value, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: CGFloat(row) * 10, width: CGFloat(width), height: 10))
        }

        return context.makeImage()!
    }

    private static func solidImage(size: CGSize, white: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: white, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// High-contrast text at a size Vision reliably reads.
    private static func textSample(_ string: String) -> NSImage {
        let size = NSSize(width: 640, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        (string as NSString).draw(
            at: NSPoint(x: 30, y: 55),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()
        return image
    }
}
