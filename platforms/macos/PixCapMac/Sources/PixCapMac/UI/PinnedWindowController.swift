import Cocoa
import SwiftUI

/// A borderless always-on-top window holding a captured image.
///
/// Pins float above every other window, can be dragged anywhere, scaled with
/// the scroll wheel or ⌘+/⌘-, and are dismissed with Escape.
@available(macOS 14.0, *)
public final class PinnedWindow: NSPanel {
    private let image: NSImage
    private var currentScale: CGFloat = 1.0
    private let baseSize: CGSize

    public init(image: NSImage, at origin: CGPoint?) {
        self.image = image

        // Pins open at most half the screen so a fullscreen capture stays usable.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = screenFrame.width * 0.5
        let maxHeight = screenFrame.height * 0.5
        let fit = min(1, min(maxWidth / max(image.size.width, 1), maxHeight / max(image.size.height, 1)))
        baseSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)

        super.init(
            contentRect: NSRect(origin: .zero, size: baseSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pins should not appear inside later captures.
        sharingType = .none

        contentView = NSHostingView(rootView: PinnedImageView(
            image: image,
            onClose: { [weak self] in self?.dismiss() },
            onCopy: { [weak self] in
                guard let self else { return }
                ImageExporter.copyToClipboard(self.image)
            },
            onSave: { [weak self] in self?.saveAs() },
            onEdit: { [weak self] in
                guard let self else { return }
                EditorWindowController.openEditor(with: self.image, mode: "pin")
                self.dismiss()
            }
        ))

        if let origin {
            setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        } else {
            center()
        }
    }

    public override var canBecomeKey: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            dismiss()
        case 24, 69: // = / keypad +
            if event.modifierFlags.contains(.command) { rescale(by: 1.1) } else { super.keyDown(with: event) }
        case 27, 78: // - / keypad -
            if event.modifierFlags.contains(.command) { rescale(by: 0.9) } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        rescale(by: 1 + (event.scrollingDeltaY * 0.005))
    }

    private func rescale(by factor: CGFloat) {
        currentScale = min(4.0, max(0.2, currentScale * factor))
        let size = NSSize(width: baseSize.width * currentScale, height: baseSize.height * currentScale)
        setContentSize(size)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PixCap-Pin.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = ImageExporter.data(from: image, format: .png) else { return }
        try? data.write(to: url)
    }

    fileprivate func dismiss() {
        PinnedWindowController.close(self)
    }
}

@available(macOS 14.0, *)
private struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hovering {
                HStack(spacing: 6) {
                    pinButton("wand.and.stars", help: "Edit", action: onEdit)
                    pinButton("doc.on.doc", help: "Copy", action: onCopy)
                    pinButton("square.and.arrow.down", help: "Save as…", action: onSave)
                    pinButton("xmark", help: "Close pin", action: onClose)
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: image) }
    }

    private func pinButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Tracks every open pin so they can be hidden or closed as a group.
@available(macOS 14.0, *)
public enum PinnedWindowController {
    private static var pins: [PinnedWindow] = []
    private static var hidden = false

    /// Pins an image, cascading each new pin so they do not stack exactly.
    public static func pin(image: NSImage, at origin: CGPoint? = nil) {
        let offset = CGFloat(pins.count % 8) * 24
        let position = origin ?? defaultOrigin(for: image, offset: offset)

        let window = PinnedWindow(image: image, at: position)
        pins.append(window)
        hidden = false
        window.orderFrontRegardless()
    }

    public static func close(_ window: PinnedWindow) {
        window.orderOut(nil)
        pins.removeAll { $0 === window }
    }

    public static func closeAll() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
    }

    /// Hides or reveals every pin without discarding them.
    public static func toggleVisibility() {
        hidden.toggle()
        pins.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    public static var count: Int { pins.count }

    private static func defaultOrigin(for image: NSImage, offset: CGFloat) -> CGPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return CGPoint(x: 120, y: 120) }
        return CGPoint(
            x: frame.minX + 80 + offset,
            y: frame.maxY - image.size.height - 120 - offset
        )
    }
}
