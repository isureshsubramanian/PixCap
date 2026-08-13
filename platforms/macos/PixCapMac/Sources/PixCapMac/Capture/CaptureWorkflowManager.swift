import Cocoa
import SwiftUI
import AppKit
import UserNotifications

/// Runs the post-capture pipeline described by the After-Capture Workflow preferences:
/// save → clipboard → sound → notification → Quick Access → editor → history.
@available(macOS 14.0, *)
public final class CaptureWorkflowManager {
    public static let shared = CaptureWorkflowManager()

    private init() {}

    public func handleCapture(_ result: CaptureResult) {
        let action = Settings.afterCaptureAction

        // A file on disk backs both the history entry and the Quick Access actions,
        // so every capture is written even when the chosen action is something else.
        let savedURL = ImageExporter.save(
            image: result.image,
            mode: result.mode,
            appName: result.appName,
            windowTitle: result.windowTitle
        )

        if Settings.bool(SettingsKey.autoCopyClipboard) || action == .copyToClipboard {
            ImageExporter.copyToClipboard(result.image)
        }

        if Settings.bool(SettingsKey.playCaptureSound) {
            NSSound(named: "Grab")?.play()
        }

        DispatchQueue.main.async {
            if let savedURL {
                ScreenshotHistoryManager.shared.add(image: result.image, url: savedURL, mode: result.mode)
            }

            if Settings.bool(SettingsKey.showQuickAccess) {
                QuickAccessOverlayController.show(result: result, savedURL: savedURL)
            }

            if Settings.bool(SettingsKey.pinToScreenDefault) {
                PinnedWindowController.pin(image: result.image)
            }

            switch action {
            case .openEditor:
                EditorWindowController.openEditor(with: result.image, mode: result.mode, sourceURL: savedURL)
            case .copyToClipboard, .saveToDisk:
                break
            }

            if Settings.bool(SettingsKey.showNotifications) {
                let name = savedURL?.lastPathComponent ?? "Capture ready"
                self.notify(title: "Screenshot captured", body: name)
            }
        }
    }

    /// Files a finished recording: history entry, notification, and reveal.
    public func handleRecording(url: URL) {
        let thumbnail = RecordingThumbnail.firstFrame(of: url)

        if let thumbnail {
            ScreenshotHistoryManager.shared.add(image: thumbnail, url: url, mode: "recording")
        }

        if Settings.bool(SettingsKey.showNotifications) {
            notify(title: "Recording saved", body: url.lastPathComponent)
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Runs OCR over a capture and stores the text so history search can find it.
    ///
    /// Returns the recognised text, or nil when nothing was found.
    @discardableResult
    public func indexText(for image: NSImage, savedURL: URL?, mode: String) -> String? {
        guard Settings.bool(SettingsKey.ocrStoreInHistory),
              let recognition = try? OCRService.recognize(in: image, includeBarcodes: false),
              !recognition.isEmpty else {
            return nil
        }
        return recognition.textPreservingLineBreaks
    }

    /// Posts a notification on behalf of another component.
    public func notifyPublic(title: String, body: String) {
        notify(title: title, body: body)
    }

    /// Surfaces a capture failure without interrupting the user's flow.
    public func handleFailure(_ error: Error) {
        NSLog("PixCap capture failed: \(error.localizedDescription)")

        DispatchQueue.main.async {
            // macOS grants Screen Recording per process at launch. If the user
            // ticked PixCap in System Settings while it was running, the toggle
            // looks on but this process is still denied — the only fix is a
            // relaunch, so say that rather than repeating the raw TCC error.
            if !CGPreflightScreenCaptureAccess() {
                self.presentPermissionAlert()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Capture failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Explains the relaunch requirement and offers to do it.
    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "PixCap needs to be relaunched"
        alert.informativeText = """
            Screen Recording permission is granted to an app when it starts, so \
            enabling PixCap in System Settings does not affect the copy that is \
            already running.

            If you have already enabled PixCap under Privacy & Security › Screen \
            & System Audio Recording, just relaunch. Otherwise enable it there first.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Relaunch PixCap")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let settingsURL = URL(string: url) {
                NSWorkspace.shared.open(settingsURL)
            }
        default:
            break
        }
    }

    /// Restarts the app so a newly granted permission takes effect.
    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL

        // A bare SwiftPM binary has no bundle to reopen; ask the user instead.
        guard bundleURL.pathExtension == "app" else {
            NSLog("PixCap: not running from a bundle, cannot relaunch automatically")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Posts a user notification when running from a bundled app.
    ///
    /// `UNUserNotificationCenter` requires a bundle identifier, which a bare
    /// SwiftPM binary does not have, so this is a no-op in that configuration.
    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
