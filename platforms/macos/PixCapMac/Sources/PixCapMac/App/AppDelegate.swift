import Cocoa
import Foundation
import ScreenCaptureKit

@available(macOS 14.0, *)
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var recordingMenuItem: NSMenuItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        setupMenuBar()
        registerHotkeys()

        // Appearance preferences apply at launch and whenever they change.
        AppearanceManager.onMenuBarStyleChange = { [weak self] in self?.applyMenuBarStyle() }
        AppearanceManager.applyAll()

        ScreenCaptureEngine.shared.ensurePermission()
        print("🚀 PixCap Executive Edition initialized on Apple Silicon")
    }

    /// Applies the menu bar icon style preference to the status item.
    private func applyMenuBarStyle() {
        guard let statusItem, let button = statusItem.button else { return }

        switch AppearanceManager.menuBarIconStyle {
        case .iconOnly:
            statusItem.isVisible = true
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PixCap")
            button.title = ""
        case .iconAndText:
            statusItem.isVisible = true
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PixCap")
            button.title = " PixCap"
        case .hidden:
            // Global hotkeys keep working; relaunching restores the icon.
            statusItem.isVisible = false
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PixCap")
            button.toolTip = "PixCap Executive Screen Snapshot & Code Beautifier"
        }

        let menu = NSMenu()

        // 1. Capture actions, labelled with their live global shortcuts.
        menu.addItem(captureItem("Capture Area", action: #selector(captureAreaAction), hotkey: .captureArea))
        menu.addItem(captureItem("Capture Fullscreen", action: #selector(captureFullscreenAction), hotkey: .captureFullscreen))
        menu.addItem(captureItem("Capture Frontmost Window", action: #selector(captureWindowAction), hotkey: .captureWindow))
        menu.addItem(captureItem("Choose Window…", action: #selector(chooseWindowAction), hotkey: nil))
        menu.addItem(captureItem("Self-Timer (\(Int(Settings.selfTimerSeconds))s)", action: #selector(selfTimerAction), hotkey: .selfTimer))

        menu.addItem(NSMenuItem.separator())

        // 2. Recording, scrolling capture, OCR, and pins
        menu.addItem(captureItem("Scrolling Capture", action: #selector(scrollingCaptureAction), hotkey: .scrollingCapture))
        menu.addItem(captureItem("Capture Text (OCR)", action: #selector(ocrCaptureAction), hotkey: .captureText))

        recordingMenuItem = captureItem("Record Screen", action: #selector(recordScreenAction), hotkey: .toggleRecording)
        menu.addItem(recordingMenuItem!)
        menu.addItem(captureItem("Record GIF", action: #selector(recordGIFAction), hotkey: nil))

        menu.addItem(captureItem("Batch Capture…", action: #selector(batchCaptureAction), hotkey: .batchCapture))
        menu.addItem(captureItem("Pin to the Screen", action: #selector(pinToScreenAction), hotkey: .pinToScreen))
        menu.addItem(captureItem("Toggle Pin Visibility", action: #selector(togglePinsAction), hotkey: nil))
        menu.addItem(captureItem("Close All Pins", action: #selector(closePinsAction), hotkey: nil))

        menu.addItem(NSMenuItem.separator())

        // 3. Open & history
        menu.addItem(captureItem("Open from Clipboard", action: #selector(openClipboardAction), hotkey: nil))
        menu.addItem(captureItem("Open from File…", action: #selector(openFileAction), hotkey: nil))
        menu.addItem(captureItem("Reopen Last Capture", action: #selector(reopenClosedAction), hotkey: .restoreLastCapture))
        menu.addItem(captureItem("Screenshot History…", action: #selector(screenshotHistoryAction), hotkey: .openHistory))

        menu.addItem(NSMenuItem.separator())

        let preferences = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        let quit = NSMenuItem(title: "Quit PixCap", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func captureItem(_ title: String, action: Selector, hotkey: HotkeyAction?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hotkey, let binding = HotkeyManager.shared.binding(for: hotkey) {
            // Shown as a hint; the actual trigger is the registered global hotkey.
            item.toolTip = "Global shortcut: \(binding.displayString)"
        }
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        HotkeyManager.shared.registerAll(handlers: [
            .captureArea: { [weak self] in self?.captureArea() },
            .captureFullscreen: { [weak self] in self?.captureFullscreen() },
            .captureWindow: { [weak self] in self?.captureFrontmostWindow() },
            .selfTimer: { [weak self] in self?.startSelfTimer() },
            .captureAreaAndCopy: { [weak self] in self?.captureArea(override: .copyToClipboard) },
            .captureAreaAndSave: { [weak self] in self?.captureArea(override: .saveToDisk) },
            .openHistory: { ScreenshotHistoryWindowController.showWindow() },
            .restoreLastCapture: { [weak self] in self?.reopenLastCapture() },
            .toggleRecording: { [weak self] in self?.toggleRecording(format: Self.preferredRecordingFormat) },
            .captureText: { [weak self] in self?.captureText() },
            .scrollingCapture: { [weak self] in self?.startScrollingCapture() },
            .pinToScreen: { [weak self] in self?.pinCapture() },
            .togglePins: { PinnedWindowController.toggleVisibility() },
            .batchCapture: { [weak self] in self?.startBatchCapture() }
        ])
    }

    // MARK: - Recording

    /// Format chosen in Settings; the GIF menu item overrides it explicitly.
    private static var preferredRecordingFormat: ScreenRecorder.RecordingFormat {
        ScreenRecorder.RecordingFormat(
            rawValue: Settings.string(SettingsKey.recordingDefaultFormat, default: "MP4")
        ) ?? .mp4
    }

    private func toggleRecording(format: ScreenRecorder.RecordingFormat) {
        if ScreenRecorder.shared.isRecording {
            stopRecording()
            return
        }

        let begin: () -> Void = { [weak self] in
            Task { @MainActor in
                do {
                    try await ScreenRecorder.shared.start(format: format)
                    RecordingControlsController.show { self?.stopRecording() }
                    self?.recordingMenuItem?.title = "Stop Recording"
                } catch {
                    CaptureWorkflowManager.shared.handleFailure(error)
                }
            }
        }

        if Settings.bool(SettingsKey.showCountdown) {
            CountdownOverlayController.start(seconds: 3, completion: begin)
        } else {
            begin()
        }
    }

    private func stopRecording() {
        Task { @MainActor in
            let url = await ScreenRecorder.shared.stop()
            RecordingControlsController.hide()
            recordingMenuItem?.title = "Record Screen"

            guard let url else {
                CaptureWorkflowManager.shared.handleFailure(ScreenRecorder.RecorderError.nothingRecorded)
                return
            }

            CaptureWorkflowManager.shared.handleRecording(url: url)
        }
    }

    // MARK: - OCR

    /// Selects a region, recognises its text, and copies it to the clipboard.
    private func captureText() {
        RegionSelectionWindowController.present { rect, screen in
            guard let rect else { return }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                do {
                    let result = try await ScreenCaptureEngine.shared.captureRegion(rect: rect, on: screen)
                    let recognition = try OCRService.recognize(
                        in: result.image,
                        includeBarcodes: Settings.bool(SettingsKey.ocrDetectBarcodes)
                    )

                    guard !recognition.isEmpty else {
                        CaptureWorkflowManager.shared.notifyPublic(
                            title: "No text found",
                            body: "PixCap could not recognise any text in that region."
                        )
                        return
                    }

                    let preserve = Settings.bool(SettingsKey.ocrPreserveLineBreaks)
                    var text = preserve ? recognition.textPreservingLineBreaks : recognition.textAsParagraph
                    if text.isEmpty, let barcode = recognition.barcodes.first { text = barcode }

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)

                    CaptureWorkflowManager.shared.notifyPublic(
                        title: "Text copied",
                        body: "\(recognition.lines.count) lines\(recognition.barcodes.isEmpty ? "" : " · \(recognition.barcodes.count) code(s)")"
                    )
                } catch {
                    CaptureWorkflowManager.shared.handleFailure(error)
                }
            }
        }
    }

    // MARK: - Scrolling capture

    private func startScrollingCapture() {
        RegionSelectionWindowController.present { rect, screen in
            guard let rect else { return }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                ScrollingCaptureController.shared.begin(region: rect, screen: screen) { result in
                    guard let result else { return }
                    CaptureWorkflowManager.shared.handleCapture(result)
                }
            }
        }
    }

    // MARK: - Batch capture

    /// Starts a batch run, then immediately takes the first capture.
    private func startBatchCapture() {
        if BatchCaptureSession.shared.isActive {
            BatchCaptureSession.shared.finish()
            return
        }

        BatchCaptureSession.shared.begin()
        captureArea()
    }

    // MARK: - Pins

    private func pinCapture() {
        RegionSelectionWindowController.present { rect, screen in
            guard let rect else { return }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                do {
                    let result = try await ScreenCaptureEngine.shared.captureRegion(rect: rect, on: screen)
                    PinnedWindowController.pin(image: result.image, at: CGPoint(x: rect.minX, y: rect.minY))
                } catch {
                    CaptureWorkflowManager.shared.handleFailure(error)
                }
            }
        }
    }

    // MARK: - Capture flows

    /// Runs a region selection followed by the post-capture workflow.
    ///
    /// - Parameter override: temporarily forces a different after-capture action
    ///   (used by the "& Copy" / "& Save" shortcuts).
    private func captureArea(override: Settings.AfterCaptureAction? = nil) {
        RegionSelectionWindowController.present { rect, screen in
            guard let rect else { return }

            Task { @MainActor in
                // Let the overlay windows fully disappear before the shutter fires.
                try? await Task.sleep(nanoseconds: 120_000_000)
                await self.runCapture(override: override) {
                    try await ScreenCaptureEngine.shared.captureRegion(rect: rect, on: screen)
                }
            }
        }
    }

    private func captureFullscreen() {
        Task { @MainActor in
            await runCapture {
                try await ScreenCaptureEngine.shared.captureDisplay()
            }
        }
    }

    private func captureFrontmostWindow() {
        Task { @MainActor in
            await runCapture {
                try await ScreenCaptureEngine.shared.captureFrontmostWindow()
            }
        }
    }

    /// Executes a capture and hands the result to the workflow pipeline.
    private func runCapture(
        override: Settings.AfterCaptureAction? = nil,
        _ capture: @escaping () async throws -> CaptureResult
    ) async {
        do {
            let result = try await capture()

            // A running batch collects captures instead of opening the editor
            // once per shot, which is the whole point of the mode.
            if BatchCaptureSession.shared.add(result) {
                if Settings.bool(SettingsKey.playCaptureSound) {
                    NSSound(named: "Grab")?.play()
                }
                return
            }

            if let override {
                let key = SettingsKey.afterCaptureAction
                let previous = Settings.string(key, default: "Open Editor")
                UserDefaults.standard.set(override.rawValue, forKey: key)
                CaptureWorkflowManager.shared.handleCapture(result)
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                CaptureWorkflowManager.shared.handleCapture(result)
            }
        } catch {
            CaptureWorkflowManager.shared.handleFailure(error)
        }
    }

    private func startSelfTimer() {
        let seconds = Settings.selfTimerSeconds
        CountdownOverlayController.start(seconds: seconds) { [weak self] in
            self?.captureArea()
        }
    }

    private func reopenLastCapture() {
        ScreenshotHistoryManager.shared.reload()
        if let image = ScreenshotHistoryManager.shared.mostRecentImage {
            EditorWindowController.openEditor(with: image)
        } else {
            EditorWindowController.openEditor()
        }
    }

    // MARK: - Menu actions

    @objc private func captureAreaAction() { captureArea() }

    @objc private func captureFullscreenAction() { captureFullscreen() }

    @objc private func captureWindowAction() { captureFrontmostWindow() }

    @objc private func chooseWindowAction() {
        Task { @MainActor in
            do {
                let windows = try await ScreenCaptureEngine.shared.shareableWindows()
                guard !windows.isEmpty else {
                    CaptureWorkflowManager.shared.handleFailure(CaptureError.windowNotFound)
                    return
                }
                WindowPickerController.present(windows: windows) { windowID in
                    guard let windowID else { return }
                    Task { @MainActor in
                        await self.runCapture {
                            try await ScreenCaptureEngine.shared.captureWindow(windowID: windowID)
                        }
                    }
                }
            } catch {
                CaptureWorkflowManager.shared.handleFailure(error)
            }
        }
    }

    @objc private func selfTimerAction() { startSelfTimer() }

    @objc private func scrollingCaptureAction() { startScrollingCapture() }

    @objc private func ocrCaptureAction() { captureText() }

    @objc private func recordScreenAction() { toggleRecording(format: Self.preferredRecordingFormat) }

    @objc private func recordGIFAction() { toggleRecording(format: .gif) }

    @objc private func batchCaptureAction() { startBatchCapture() }

    @objc private func pinToScreenAction() { pinCapture() }

    @objc private func togglePinsAction() { PinnedWindowController.toggleVisibility() }

    @objc private func closePinsAction() { PinnedWindowController.closeAll() }

    @objc private func openClipboardAction() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            EditorWindowController.openEditor(with: image, mode: "clipboard")
        } else {
            EditorWindowController.openEditor()
        }
    }

    @objc private func openFileAction() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        if openPanel.runModal() == .OK, let url = openPanel.url, let image = NSImage(contentsOf: url) {
            EditorWindowController.openEditor(with: image, mode: "file")
        }
    }

    @objc private func reopenClosedAction() { reopenLastCapture() }

    @objc private func screenshotHistoryAction() {
        ScreenshotHistoryWindowController.showWindow()
    }

    @objc private func openPreferencesAction() {
        PreferencesWindowController.openPreferences()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
