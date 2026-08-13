import Foundation
import ScreenCaptureKit
import Cocoa

/// A completed capture plus the context needed for file naming and history.
public struct CaptureResult {
    public let image: NSImage
    public let mode: String
    public let appName: String?
    public let windowTitle: String?

    public init(image: NSImage, mode: String, appName: String? = nil, windowTitle: String? = nil) {
        self.image = image
        self.mode = mode
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

public enum CaptureError: LocalizedError {
    case noDisplay
    case windowNotFound
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available to capture."
        case .windowNotFound: return "The requested window is no longer available."
        case .permissionDenied: return "PixCap needs Screen Recording permission in System Settings › Privacy & Security."
        }
    }
}

@available(macOS 14.0, *)
public final class ScreenCaptureEngine {
    public static let shared = ScreenCaptureEngine()

    private init() {}

    /// Pre-flights the TCC screen-recording entitlement, prompting once if needed.
    @discardableResult
    public func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Display capture

    /// Captures a full display (defaults to the one holding the mouse cursor).
    public func captureDisplay(screen: NSScreen? = nil) async throws -> CaptureResult {
        guard ensurePermission() else { throw CaptureError.permissionDenied }

        let targetScreen = screen ?? screenUnderCursor() ?? NSScreen.main
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = display(for: targetScreen, in: content) else {
            throw CaptureError.noDisplay
        }

        let scale = Settings.renderScale(for: targetScreen)
        let filter = SCContentFilter(display: display, excludingApplications: excludedApplications(in: content), exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = Settings.bool(SettingsKey.captureCursor)
        configuration.capturesAudio = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: display.width, height: display.height))

        return CaptureResult(image: image, mode: "fullscreen")
    }

    // MARK: - Region capture

    /// Captures an arbitrary screen region.
    ///
    /// - Parameter rect: region in global AppKit coordinates (origin bottom-left).
    /// - Parameter screen: the screen the region was selected on.
    public func captureRegion(rect: CGRect, on screen: NSScreen? = nil) async throws -> CaptureResult {
        guard ensurePermission() else { throw CaptureError.permissionDenied }

        let targetScreen = screen ?? screenContaining(rect) ?? NSScreen.main
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = display(for: targetScreen, in: content), let targetScreen else {
            throw CaptureError.noDisplay
        }

        let scale = Settings.renderScale(for: targetScreen)

        // ScreenCaptureKit's sourceRect is display-local with a top-left origin,
        // while AppKit rects are global with a bottom-left origin.
        let sourceRect = CGRect(
            x: rect.minX - targetScreen.frame.minX,
            y: targetScreen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        let filter = SCContentFilter(display: display, excludingApplications: excludedApplications(in: content), exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int((sourceRect.width * scale).rounded())
        configuration.height = Int((sourceRect.height * scale).rounded())
        configuration.showsCursor = Settings.bool(SettingsKey.captureCursor)
        configuration.capturesAudio = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: sourceRect.width, height: sourceRect.height))

        return CaptureResult(image: image, mode: "area")
    }

    // MARK: - Window capture

    /// Captures the frontmost window of the frontmost application (PixCap excluded).
    public func captureFrontmostWindow() async throws -> CaptureResult {
        guard ensurePermission() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let candidates = content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 40 && window.frame.height > 40
                && window.owningApplication?.bundleIdentifier != ownBundleID
        }

        // Prefer a window belonging to the app the user was just using.
        let window = candidates.first { $0.owningApplication?.processID == frontmostPID } ?? candidates.first

        guard let window else { throw CaptureError.windowNotFound }
        return try await capture(window: window)
    }

    public func captureWindow(windowID: CGWindowID) async throws -> CaptureResult {
        guard ensurePermission() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        return try await capture(window: window)
    }

    private func capture(window: SCWindow) async throws -> CaptureResult {
        let scale = Settings.renderScale(for: screenContaining(window.frame))
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        // Window shadow is captured as transparent padding around the window.
        configuration.ignoreShadowsSingleWindow = !Settings.bool(SettingsKey.captureWindowShadow)

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let image = NSImage(cgImage: cgImage, size: window.frame.size)

        return CaptureResult(
            image: image,
            mode: "window",
            appName: window.owningApplication?.applicationName,
            windowTitle: window.title
        )
    }

    /// On-screen windows suitable for a "choose a window" picker.
    public func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter {
            $0.isOnScreen
                && $0.windowLayer == 0
                && $0.frame.width > 40 && $0.frame.height > 40
                && $0.owningApplication?.bundleIdentifier != ownBundleID
                && !($0.title ?? "").isEmpty
        }
    }

    // MARK: - Helpers

    /// PixCap's own windows are excluded so overlays never bleed into a capture.
    private func excludedApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    }

    private func display(for screen: NSScreen?, in content: SCShareableContent) -> SCDisplay? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return content.displays.first
        }
        return content.displays.first { $0.displayID == number.uint32Value } ?? content.displays.first
    }

    private func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }
}
