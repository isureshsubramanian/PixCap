import Cocoa
import ScreenCaptureKit

@available(macOS 14.0, *)
public protocol RegionSelectionDelegate: AnyObject {
    func didSelectRegion(_ rect: CGRect, on screen: NSScreen)
    func didCancelRegionSelection()
}

@available(macOS 14.0, *)
public final class RegionSelectionOverlayView: NSView {
    public weak var delegate: RegionSelectionDelegate?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var selectionRect: NSRect?

    override public var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    // Keeping the crosshair up takes three overlapping mechanisms. Cursor rects
    // alone are unreliable here: a borderless window at .screenSaver level often
    // never has its rects validated, so the pointer stays an arrow.
    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override public func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override public func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override public func mouseMoved(with event: NSEvent) {
        // Some apps reset the cursor as the pointer crosses their windows;
        // re-asserting on movement keeps the crosshair stable everywhere.
        NSCursor.crosshair.set()
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw translucent dark background mask
        NSColor.black.withAlphaComponent(0.4).setFill()
        dirtyRect.fill()

        guard let rect = selectionRect else { return }

        // Clear out the selection rectangle (highlight selected region)
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // Selection boundary border line
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2.0
        path.stroke()

        // Dimension overlay pill tag (width x height)
        let dimText = "\(Int(rect.width)) × \(Int(rect.height)) px"
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = dimText.size(withAttributes: attrs)
        let tagRect = NSRect(
            x: rect.origin.x,
            y: (rect.origin.y - textSize.height - 8 > 0) ? rect.origin.y - textSize.height - 8 : rect.origin.y + rect.height + 4,
            width: textSize.width + 16,
            height: textSize.height + 6
        )

        NSColor.black.withAlphaComponent(0.75).setFill()
        let tagPath = NSBezierPath(roundedRect: tagRect, xRadius: 4, yRadius: 4)
        tagPath.fill()

        dimText.draw(at: NSPoint(x: tagRect.origin.x + 8, y: tagRect.origin.y + 3), withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()
    }

    override public func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        selectionRect = nil
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentPoint = point

        selectionRect = NSRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(start.x - point.x),
            height: abs(start.y - point.y)
        )
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width > 10, rect.height > 10, let screen = window?.screen else {
            delegate?.didCancelRegionSelection()
            return
        }

        // Convert view coordinates (screen-local, bottom-left) to global AppKit coordinates.
        let screenRect = CGRect(
            x: screen.frame.origin.x + rect.origin.x,
            y: screen.frame.origin.y + rect.origin.y,
            width: rect.width,
            height: rect.height
        )

        delegate?.didSelectRegion(screenRect, on: screen)
    }

    override public func keyDown(with event: NSEvent) {
        // Escape key cancels region selection
        if event.keyCode == 53 {
            delegate?.didCancelRegionSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Right-click also cancels, matching what most capture tools do.
    override public func rightMouseDown(with event: NSEvent) {
        delegate?.didCancelRegionSelection()
    }
}

/// A borderless window that can still receive key events.
///
/// `NSWindow` refuses key status for borderless windows by default, so the
/// overlay's `keyDown` never fired and Escape did nothing. Overriding this is
/// what makes the cancel key work.
@available(macOS 14.0, *)
final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presents the selection overlay across every attached display.
@available(macOS 14.0, *)
public final class RegionSelectionWindowController: NSObject, RegionSelectionDelegate {
    private var windows: [NSWindow] = []
    private var completionHandler: ((CGRect?, NSScreen?) -> Void)?
    /// Tracks the NSCursor push so it is balanced by exactly one pop.
    private var didPushCursor = false
    /// Backstop for Escape, in case another app takes key focus mid-selection.
    private var escapeMonitor: Any?
    private static var activeController: RegionSelectionWindowController?

    public static func present(completion: @escaping (CGRect?, NSScreen?) -> Void) {
        // Only one selection session at a time.
        activeController?.dismiss()

        let controller = RegionSelectionWindowController()
        controller.completionHandler = completion
        activeController = controller

        for screen in NSScreen.screens {
            let window = RegionSelectionWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            // Keep the overlay out of any capture taken while it is visible.
            window.sharingType = .none

            let overlayView = RegionSelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            overlayView.delegate = controller
            window.contentView = overlayView

            controller.windows.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(overlayView)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Push after the windows are up: the cursor stack is global, so this
        // holds the crosshair even over other applications' windows.
        NSCursor.crosshair.push()
        controller.didPushCursor = true

        controller.installEscapeMonitor()
    }

    /// Watches for Escape while a selection is in progress.
    ///
    /// The overlay's own `keyDown` handles the normal case; this catches the
    /// rest, including a selection started from a global hotkey while another
    /// application still holds focus.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.didCancelRegionSelection()
            return nil
        }
    }

    public func didSelectRegion(_ rect: CGRect, on screen: NSScreen) {
        let completion = completionHandler
        dismiss()
        completion?(rect, screen)
    }

    public func didCancelRegionSelection() {
        let completion = completionHandler
        dismiss()
        completion?(nil, nil)
    }

    private func dismiss() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        completionHandler = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if RegionSelectionWindowController.activeController === self {
            RegionSelectionWindowController.activeController = nil
        }
    }
}
