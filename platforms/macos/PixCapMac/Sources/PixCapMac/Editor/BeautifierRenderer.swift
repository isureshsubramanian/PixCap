import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Window chrome drawn around the captured image.
public enum WindowFrameStyle: String, CaseIterable, Identifiable {
    case none = "None"
    case macOS = "macOS"
    case windows = "Windows"
    case minimal = "Minimal"

    public var id: String { rawValue }

    var headerHeight: CGFloat { self == .none ? 0 : 34 }
}

/// Output aspect-ratio constraint. The canvas only ever grows to satisfy it.
public enum AspectRatioPreset: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case fourFive = "4:5"

    public var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .fourFive: return 4.0 / 5.0
        }
    }
}

/// Pattern layered over the background — the differentiator Chalk.ist has and
/// no screenshot tool offers.
public enum CanvasTexture: String, CaseIterable, Identifiable, Equatable {
    case none = "None"
    case grain = "Grain"
    case paper = "Paper"
    case linen = "Linen"
    case dots = "Dots"
    case grid = "Grid"

    public var id: String { rawValue }
}

/// Where the canvas background comes from.
public enum BackgroundSelection: Equatable {
    case preset(id: String)
    case desktopWallpaper
    case customImage(url: URL)
}

/// Everything that describes the beautified canvas around a screenshot.
public struct BeautifyConfig: Equatable {
    public var background: BackgroundSelection
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var shadowBlur: CGFloat
    public var shadowOpacity: CGFloat
    public var frameStyle: WindowFrameStyle
    public var aspectRatio: AspectRatioPreset
    public var frameTitle: String?
    public var backgroundBlur: CGFloat
    /// Non-destructive crop in source-image points; nil uses the whole image.
    public var crop: CGRect?
    /// Grain overlay strength, 0 = off.
    public var noiseIntensity: CGFloat
    /// Texture pattern layered over the background.
    public var texture: CanvasTexture
    /// Perspective tilt in degrees: x rotates about the horizontal axis.
    public var tiltX: CGFloat
    public var tiltY: CGFloat

    public init(
        background: BackgroundSelection = .preset(id: "azure-mesh"),
        padding: CGFloat = 32,
        cornerRadius: CGFloat = 16,
        shadowBlur: CGFloat = 24,
        shadowOpacity: CGFloat = 0.35,
        frameStyle: WindowFrameStyle = .macOS,
        aspectRatio: AspectRatioPreset = .auto,
        frameTitle: String? = nil,
        backgroundBlur: CGFloat = 0,
        crop: CGRect? = nil,
        noiseIntensity: CGFloat = 0,
        texture: CanvasTexture = .none,
        tiltX: CGFloat = 0,
        tiltY: CGFloat = 0
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowBlur = shadowBlur
        self.shadowOpacity = shadowOpacity
        self.frameStyle = frameStyle
        self.aspectRatio = aspectRatio
        self.frameTitle = frameTitle
        self.backgroundBlur = backgroundBlur
        self.crop = crop
        self.noiseIntensity = noiseIntensity
        self.texture = texture
        self.tiltX = tiltX
        self.tiltY = tiltY
    }

    /// Builds a config from the user's saved Canvas & Beautification defaults.
    public static func fromPreferences() -> BeautifyConfig {
        BeautifyConfig(
            background: .preset(id: Settings.string(SettingsKey.defaultBackgroundPreset, default: "azure-mesh")),
            padding: CGFloat(Settings.double(SettingsKey.defaultPadding)),
            cornerRadius: CGFloat(Settings.double(SettingsKey.defaultCornerRadius)),
            shadowBlur: CGFloat(Settings.double(SettingsKey.defaultShadowBlur)),
            frameStyle: WindowFrameStyle(rawValue: Settings.string(SettingsKey.defaultWindowFrame, default: "macOS")) ?? .macOS
        )
    }
}

/// Geometry of a laid-out canvas, in canvas points with a top-left origin.
public struct BeautifyLayout {
    public let canvasSize: CGSize
    /// Window chrome + image.
    public let frameRect: CGRect
    /// The visible (possibly cropped) screenshot area.
    public let imageRect: CGRect
    /// Crop offset applied to annotation coordinates.
    public let cropOrigin: CGPoint
}

/// Composites a captured screenshot into a beautified canvas.
///
/// The same routine drives the editor preview and the exported file, so what the
/// user sees is exactly what is written to disk — only `scale` differs.
public enum BeautifierRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Layout

    /// Effective source rectangle after any crop, clamped to the image bounds.
    public static func sourceRect(imageSize: CGSize, config: BeautifyConfig) -> CGRect {
        let full = CGRect(origin: .zero, size: imageSize)
        guard let crop = config.crop else { return full }

        let clamped = crop.intersection(full)
        return (clamped.isNull || clamped.width < 1 || clamped.height < 1) ? full : clamped
    }

    public static func layout(imageSize: CGSize, config: BeautifyConfig) -> BeautifyLayout {
        let source = sourceRect(imageSize: imageSize, config: config)
        let header = config.frameStyle.headerHeight
        let frameSize = CGSize(width: source.width, height: source.height + header)

        var canvasSize = CGSize(
            width: frameSize.width + config.padding * 2,
            height: frameSize.height + config.padding * 2
        )

        if let ratio = config.aspectRatio.ratio {
            let currentRatio = canvasSize.width / canvasSize.height
            if currentRatio < ratio {
                canvasSize.width = canvasSize.height * ratio
            } else if currentRatio > ratio {
                canvasSize.height = canvasSize.width / ratio
            }
        }

        let frameOrigin = CGPoint(
            x: (canvasSize.width - frameSize.width) / 2,
            y: (canvasSize.height - frameSize.height) / 2
        )
        let frameRect = CGRect(origin: frameOrigin, size: frameSize)
        let imageRect = CGRect(
            x: frameRect.minX,
            y: frameRect.minY + header,
            width: source.width,
            height: source.height
        )

        return BeautifyLayout(
            canvasSize: canvasSize,
            frameRect: frameRect,
            imageRect: imageRect,
            cropOrigin: source.origin
        )
    }

    // MARK: - Rendering

    /// Renders the beautified canvas.
    ///
    /// - Parameter scale: output pixels per canvas point. Use the screen's
    ///   backing scale for preview, and the capture's native scale for export.
    public static func render(
        image: NSImage,
        annotations: [AnnotationItem] = [],
        config: BeautifyConfig,
        scale: CGFloat = 2.0
    ) -> NSImage? {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let layout = layout(imageSize: imageSize, config: config)
        let pixelWidth = Int((layout.canvasSize.width * scale).rounded())
        let pixelHeight = Int((layout.canvasSize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // Work in canvas points with a top-left origin, matching annotation space.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previousContext }

        drawBackground(in: context, layout: layout, config: config)
        drawTexture(in: context, layout: layout, config: config)

        // Blur/pixelate annotations modify the screenshot itself, so they are
        // baked in before the frame is drawn.
        let baseImage = screenshotCGImage(image)
        let redactedImage = baseImage.map {
            applyPixelRedaction(to: $0, imageSize: imageSize, annotations: annotations)
        } ?? nil

        drawFrame(
            in: context,
            layout: layout,
            config: config,
            imageSize: imageSize,
            screenshot: redactedImage ?? baseImage
        )

        drawAnnotations(annotations, in: context, layout: layout)

        guard let cgImage = context.makeImage() else { return nil }
        let rendered = NSImage(cgImage: cgImage, size: layout.canvasSize)

        // Perspective is applied to the finished canvas, so the tilt carries the
        // background, frame, and annotations together as one plane.
        if config.tiltX != 0 || config.tiltY != 0 {
            return applyPerspective(to: rendered, tiltX: config.tiltX, tiltY: config.tiltY)
        }
        return rendered
    }

    /// Deterministic noise so a given canvas always renders identically —
    /// re-rendering on every slider tick must not make the grain crawl.
    struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

        mutating func next(upTo bound: UInt64) -> UInt64 {
            guard bound > 0 else { return 0 }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state % bound
        }
    }

    private static func screenshotCGImage(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    // MARK: - Background

    private static func drawBackground(in context: CGContext, layout: BeautifyLayout, config: BeautifyConfig) {
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)

        switch config.background {
        case .preset(let id):
            guard let preset = PixCapBridge.shared.preset(id: id) else {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(canvasRect)
                return
            }
            drawFill(preset.fill, in: context, rect: canvasRect)

        case .desktopWallpaper:
            if let url = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }),
               let wallpaper = NSImage(contentsOf: url) {
                drawScaledToFill(wallpaper, in: context, rect: canvasRect, blur: config.backgroundBlur)
            } else {
                drawFill(.gradient(angle: 135, stops: [(0, "#0093E9"), (1, "#80D0C7")]), in: context, rect: canvasRect)
            }

        case .customImage(let url):
            if let custom = NSImage(contentsOf: url) {
                drawScaledToFill(custom, in: context, rect: canvasRect, blur: config.backgroundBlur)
            }
        }
    }

    private static func drawFill(_ fill: BackgroundFill, in context: CGContext, rect: CGRect) {
        switch fill {
        case .transparent:
            break // true alpha canvas

        case .solid(let hex):
            context.setFillColor((NSColor(hex: hex) ?? .black).cgColor)
            context.fill(rect)

        case .glassmorphism(_, let hex, let opacity):
            let base = NSColor(hex: hex) ?? .black
            context.setFillColor(base.withAlphaComponent(CGFloat(opacity)).cgColor)
            context.fill(rect)

        case .gradient(let angle, let stops):
            let colors = stops.compactMap { (NSColor(hex: $0.hex) ?? .black).cgColor } as CFArray
            let locations = stops.map { CGFloat($0.position) }
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors,
                locations: locations
            ) else { return }

            let radians = angle * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            let half = max(rect.width, rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = CGPoint(x: center.x - dx * half, y: center.y - dy * half)
            let end = CGPoint(x: center.x + dx * half, y: center.y + dy * half)

            context.saveGState()
            context.clip(to: rect)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
    }

    /// Aspect-fills `image` into `rect`, cropping the overflow.
    private static func drawScaledToFill(_ image: NSImage, in context: CGContext, rect: CGRect, blur: CGFloat) {
        guard var cgImage = screenshotCGImage(image) else { return }

        if blur > 0, let blurred = gaussianBlur(cgImage, radius: blur) {
            cgImage = blurred
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.clip(to: rect)
        draw(cgImage, in: drawRect, context: context)
        context.restoreGState()
    }

    // MARK: - Texture

    /// Lays a repeating pattern and/or film grain over the background.
    ///
    /// Drawn before the window frame so the screenshot itself stays clean —
    /// texture belongs to the canvas, not the content.
    private static func drawTexture(in context: CGContext, layout: BeautifyLayout, config: BeautifyConfig) {
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        switch config.texture {
        case .none:
            break

        case .grain:
            break // handled by the noise pass below

        case .paper:
            // Short random fibres, like the tooth of uncoated stock.
            context.saveGState()
            context.clip(to: canvas)
            context.setLineWidth(0.7)
            var generator = SeededGenerator(seed: 7)
            for _ in 0..<Int(canvas.width * canvas.height / 900) {
                let x = CGFloat(generator.next(upTo: UInt64(canvas.width)))
                let y = CGFloat(generator.next(upTo: UInt64(canvas.height)))
                let length = CGFloat(generator.next(upTo: 6)) + 2
                let bright = generator.next(upTo: 2) == 0
                context.setStrokeColor(NSColor(white: bright ? 1 : 0, alpha: 0.05).cgColor)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + length, y: y + CGFloat(generator.next(upTo: 3)) - 1))
                context.strokePath()
            }
            context.restoreGState()

        case .linen:
            // Fine cross-hatch weave.
            context.saveGState()
            context.clip(to: canvas)
            context.setLineWidth(0.6)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.045).cgColor)
            var offset: CGFloat = 0
            while offset < canvas.width + canvas.height {
                context.move(to: CGPoint(x: offset, y: 0))
                context.addLine(to: CGPoint(x: offset - canvas.height, y: canvas.height))
                context.move(to: CGPoint(x: offset - canvas.height, y: 0))
                context.addLine(to: CGPoint(x: offset, y: canvas.height))
                offset += 4
            }
            context.strokePath()
            context.restoreGState()

        case .dots:
            context.saveGState()
            context.clip(to: canvas)
            context.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
            let spacing: CGFloat = 14
            var y: CGFloat = spacing / 2
            while y < canvas.height {
                var x: CGFloat = spacing / 2
                while x < canvas.width {
                    context.fillEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                    x += spacing
                }
                y += spacing
            }
            context.restoreGState()

        case .grid:
            context.saveGState()
            context.clip(to: canvas)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.07).cgColor)
            context.setLineWidth(0.7)
            let spacing: CGFloat = 24
            var x: CGFloat = 0
            while x < canvas.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: canvas.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y < canvas.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: canvas.width, y: y))
                y += spacing
            }
            context.strokePath()
            context.restoreGState()
        }

        // Film grain, independent of the pattern choice.
        let intensity = config.texture == .grain
            ? max(config.noiseIntensity, 0.35)
            : config.noiseIntensity
        guard intensity > 0 else { return }

        context.saveGState()
        context.clip(to: canvas)
        var generator = SeededGenerator(seed: 42)
        let step: CGFloat = 2
        var y: CGFloat = 0
        while y < canvas.height {
            var x: CGFloat = 0
            while x < canvas.width {
                let value = CGFloat(generator.next(upTo: 100)) / 100.0
                let alpha = (value - 0.5) * 0.12 * intensity
                context.setFillColor(NSColor(white: alpha > 0 ? 1 : 0, alpha: abs(alpha)).cgColor)
                context.fill(CGRect(x: x, y: y, width: step, height: step))
                x += step
            }
            y += step
        }
        context.restoreGState()
    }

    // MARK: - Perspective

    /// Applies a perspective tilt to a rendered canvas.
    ///
    /// CoreGraphics is affine only, so this goes through Core Image's
    /// perspective transform, which takes the four destination corners.
    static func applyPerspective(to image: NSImage, tiltX: CGFloat, tiltY: CGFloat) -> NSImage? {
        guard tiltX != 0 || tiltY != 0 else { return image }

        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return image
        }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent

        // Convert degrees into a corner inset: a positive X tilt pushes the top
        // edge away, narrowing it, as if the canvas leaned back.
        let insetX = extent.width * min(abs(tiltX) / 90, 0.45) / 2
        let insetY = extent.height * min(abs(tiltY) / 90, 0.45) / 2

        let topShrink = tiltX > 0 ? insetX : 0
        let bottomShrink = tiltX < 0 ? insetX : 0
        let leftShrink = tiltY > 0 ? insetY : 0
        let rightShrink = tiltY < 0 ? insetY : 0

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = input
        // Core Image works bottom-left origin.
        filter.topLeft = CGPoint(x: extent.minX + topShrink, y: extent.maxY - leftShrink)
        filter.topRight = CGPoint(x: extent.maxX - topShrink, y: extent.maxY - rightShrink)
        filter.bottomLeft = CGPoint(x: extent.minX + bottomShrink, y: extent.minY + leftShrink)
        filter.bottomRight = CGPoint(x: extent.maxX - bottomShrink, y: extent.minY + rightShrink)

        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent) else {
            return image
        }

        return NSImage(cgImage: result, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    // MARK: - Window frame

    private static func drawFrame(
        in context: CGContext,
        layout: BeautifyLayout,
        config: BeautifyConfig,
        imageSize: CGSize,
        screenshot: CGImage?
    ) {
        let radius = min(config.cornerRadius, min(layout.frameRect.width, layout.frameRect.height) / 2)
        let framePath = CGPath(
            roundedRect: layout.frameRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // Drop shadow is cast by an opaque fill under the clipped content.
        if config.shadowBlur > 0 && config.shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: max(2, config.shadowBlur / 2)),
                blur: config.shadowBlur,
                color: NSColor.black.withAlphaComponent(config.shadowOpacity).cgColor
            )
            context.addPath(framePath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(framePath)
        context.clip()

        // Header chrome
        if config.frameStyle != .none {
            let headerRect = CGRect(
                x: layout.frameRect.minX,
                y: layout.frameRect.minY,
                width: layout.frameRect.width,
                height: config.frameStyle.headerHeight
            )
            drawHeader(headerRect, style: config.frameStyle, title: config.frameTitle, in: context)
        }

        if let screenshot {
            // Draw only the cropped region, scaled 1:1 into the image rect.
            let source = sourceRect(imageSize: imageSize, config: config)
            let pixelScale = CGFloat(screenshot.width) / max(imageSize.width, 1)
            let cropInPixels = CGRect(
                x: source.minX * pixelScale,
                y: source.minY * pixelScale,
                width: source.width * pixelScale,
                height: source.height * pixelScale
            )

            let visible = screenshot.cropping(to: cropInPixels) ?? screenshot
            draw(visible, in: layout.imageRect, context: context)
        } else {
            context.setFillColor(NSColor.darkGray.cgColor)
            context.fill(layout.imageRect)
        }

        context.restoreGState()
    }

    private static func drawHeader(_ rect: CGRect, style: WindowFrameStyle, title: String?, in context: CGContext) {
        let isLight = style == .windows
        context.setFillColor((isLight ? NSColor(hex: "#F3F3F3")! : NSColor(hex: "#2B2B33")!).cgColor)
        context.fill(rect)

        // Hairline under the header
        context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5))

        let centerY = rect.midY

        switch style {
        case .macOS:
            let colors = ["#FF5F56", "#FFBD2E", "#27C93F"]
            for (index, hex) in colors.enumerated() {
                let center = CGPoint(x: rect.minX + 20 + CGFloat(index) * 20, y: centerY)
                context.setFillColor((NSColor(hex: hex) ?? .gray).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            }

        case .minimal:
            for index in 0..<3 {
                let center = CGPoint(x: rect.minX + 20 + CGFloat(index) * 18, y: centerY)
                context.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            }

        case .windows:
            // Fluent-style minimize / maximize / close glyphs on the trailing edge.
            let glyphColor = NSColor(hex: "#1F1F1F")!.cgColor
            context.setStrokeColor(glyphColor)
            context.setLineWidth(1.2)
            let right = rect.maxX

            context.move(to: CGPoint(x: right - 108, y: centerY))
            context.addLine(to: CGPoint(x: right - 96, y: centerY))
            context.strokePath()

            context.stroke(CGRect(x: right - 70, y: centerY - 5, width: 10, height: 10))

            context.move(to: CGPoint(x: right - 34, y: centerY - 5))
            context.addLine(to: CGPoint(x: right - 24, y: centerY + 5))
            context.move(to: CGPoint(x: right - 24, y: centerY - 5))
            context.addLine(to: CGPoint(x: right - 34, y: centerY + 5))
            context.strokePath()

        case .none:
            break
        }

        if let title, !title.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isLight ? NSColor(hex: "#3A3A3A")! : NSColor.white.withAlphaComponent(0.75)
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            (title as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    // MARK: - Annotations

    /// Bakes blur/pixelate regions into the screenshot before anything is drawn on top.
    private static func applyPixelRedaction(
        to image: CGImage,
        imageSize: CGSize,
        annotations: [AnnotationItem]
    ) -> CGImage? {
        let blurItems = annotations.filter { $0.tool == .blur && $0.isMeaningful }
        guard !blurItems.isEmpty else { return image }

        let pixelScale = CGFloat(image.width) / max(imageSize.width, 1)
        var output = CIImage(cgImage: image)
        let extent = output.extent

        for item in blurItems {
            let rect = item.rect
            // Image space is top-left origin; Core Image is bottom-left.
            let region = CGRect(
                x: rect.minX * pixelScale,
                y: extent.height - rect.maxY * pixelScale,
                width: rect.width * pixelScale,
                height: rect.height * pixelScale
            ).intersection(extent)
            guard !region.isNull, region.width > 1, region.height > 1 else { continue }

            let source = output.cropped(to: region)
            let processed: CIImage?

            switch item.blurStyle {
            case .gaussian:
                let filter = CIFilter.gaussianBlur()
                // Clamping stops the blur from sampling transparent pixels at the edges.
                filter.inputImage = source.clampedToExtent()
                filter.radius = Float(max(1, item.blurIntensity * pixelScale / 2))
                processed = filter.outputImage?.cropped(to: region)
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = source.clampedToExtent()
                filter.scale = Float(max(2, item.blurIntensity * pixelScale / 2))
                filter.center = CGPoint(x: region.midX, y: region.midY)
                processed = filter.outputImage?.cropped(to: region)
            }

            if let processed {
                output = processed.composited(over: output)
            }
        }

        return ciContext.createCGImage(output, from: extent) ?? image
    }

    private static func drawAnnotations(_ annotations: [AnnotationItem], in context: CGContext, layout: BeautifyLayout) {
        guard !annotations.isEmpty else { return }

        context.saveGState()
        context.clip(to: layout.imageRect)
        // Annotation coordinates are relative to the uncropped screenshot's
        // top-left corner, so the crop offset is subtracted here.
        context.translateBy(
            x: layout.imageRect.minX - layout.cropOrigin.x,
            y: layout.imageRect.minY - layout.cropOrigin.y
        )

        let imageBounds = CGRect(
            x: layout.cropOrigin.x,
            y: layout.cropOrigin.y,
            width: layout.imageRect.width,
            height: layout.imageRect.height
        )

        for item in annotations where item.tool != .blur {
            draw(item, in: context, imageBounds: imageBounds)
        }

        context.restoreGState()
    }

    /// Draws a single annotation. Shared by the renderer and the live drag preview.
    ///
    /// - Parameter imageBounds: visible image area, needed by tools such as
    ///   spotlight that dim everything outside their own rectangle.
    public static func draw(_ item: AnnotationItem, in context: CGContext, imageBounds: CGRect? = nil) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(item.color.cgColor)
        context.setLineWidth(item.strokeWidth)
        if item.dashed {
            let dash = max(item.strokeWidth * 3, 6)
            context.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
        }

        switch item.tool {
        case .rectangle:
            context.addRect(item.rect)
            if item.filled {
                context.setFillColor(item.color.withAlphaComponent(0.35).cgColor)
                context.drawPath(using: .fillStroke)
            } else {
                context.strokePath()
            }

        case .ellipse:
            context.addEllipse(in: item.rect)
            if item.filled {
                context.setFillColor(item.color.withAlphaComponent(0.35).cgColor)
                context.drawPath(using: .fillStroke)
            } else {
                context.strokePath()
            }

        case .line:
            context.move(to: item.start)
            context.addLine(to: item.end)
            context.strokePath()

        case .arrow:
            drawArrow(item, in: context)

        case .freehand:
            guard let first = item.points.first else { break }
            context.move(to: first)
            for point in item.points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()

        case .highlight:
            context.setBlendMode(.multiply)
            context.setFillColor(item.color.withAlphaComponent(0.35).cgColor)
            context.fill(item.rect)

        case .redaction:
            // Opaque block — the pixels underneath are never recoverable from the export.
            context.setFillColor(item.color.withAlphaComponent(1.0).cgColor)
            context.fill(item.rect)

        case .spotlight:
            guard let bounds = imageBounds else { break }
            context.setFillColor(NSColor.black.withAlphaComponent(item.spotlightDim).cgColor)
            context.addRect(bounds)
            context.addRect(item.rect)
            // Even-odd leaves the inner rectangle untouched.
            context.fillPath(using: .evenOdd)

        case .counter:
            let radius = item.counterRadius
            let circle = CGRect(
                x: item.start.x - radius,
                y: item.start.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(item.color.cgColor)
            context.fillEllipse(in: circle)

            let label = "\(item.number)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                withAttributes: attributes
            )

        case .text:
            guard !item.text.isEmpty else { break }
            (item.text as NSString).draw(at: item.start, withAttributes: item.textAttributes())

        case .blur, .select, .crop:
            break
        }

        context.restoreGState()
    }

    private static func drawArrow(_ item: AnnotationItem, in context: CGContext) {
        let start = item.start
        let end = item.end
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 1 else { return }

        var tangent = CGPoint(x: end.x - start.x, y: end.y - start.y)

        if item.curvedArrow {
            // Bow the shaft out perpendicular to the straight line, then take the
            // curve's end tangent so the head stays aligned with the stroke.
            let normal = CGPoint(x: -(end.y - start.y) / length, y: (end.x - start.x) / length)
            let bow = min(length * 0.18, 60)
            let control = CGPoint(
                x: (start.x + end.x) / 2 + normal.x * bow,
                y: (start.y + end.y) / 2 + normal.y * bow
            )
            context.move(to: start)
            context.addQuadCurve(to: end, control: control)
            context.strokePath()
            tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
        } else {
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }

        guard item.arrowHead != .none else { return }

        let angle = atan2(tangent.y, tangent.x)
        let headLength = max(12, item.strokeWidth * 4)
        let spread = CGFloat.pi / 7

        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )

        context.setLineDash(phase: 0, lengths: [])

        switch item.arrowHead {
        case .filled:
            context.move(to: end)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.setFillColor(item.color.cgColor)
            context.fillPath()
        case .open:
            context.move(to: left)
            context.addLine(to: end)
            context.addLine(to: right)
            context.strokePath()
        case .none:
            break
        }
    }

    // MARK: - Helpers

    /// Draws a `CGImage` right-way-up inside a flipped (top-left origin) context.
    private static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }
}
