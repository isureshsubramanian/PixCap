import Foundation
import AppKit
import SwiftUI

/// Drives a scrolling capture: repeatedly grabs the chosen region while the user
/// scrolls, then hands the frames to the Rust stitcher.
///
/// The user controls pacing — PixCap does not synthesise scroll events, so this
/// works with any app, including ones that ignore programmatic scrolling.
@available(macOS 14.0, *)
public final class ScrollingCaptureController: ObservableObject {
    public static let shared = ScrollingCaptureController()

    @Published public private(set) var frameCount = 0
    @Published public private(set) var isCapturing = false

    private var region: CGRect = .zero
    private var screen: NSScreen?
    private var frameURLs: [URL] = []
    private var workingDirectory: URL?
    private var completion: ((CaptureResult?) -> Void)?

    private init() {}

    /// Starts a session: the user scrolls, PixCap grabs a frame on each request.
    public func begin(region: CGRect, screen: NSScreen?, completion: @escaping (CaptureResult?) -> Void) {
        cleanUp()

        self.region = region
        self.screen = screen
        self.completion = completion
        self.frameURLs = []
        self.frameCount = 0
        self.isCapturing = true

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixcap-scroll-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workingDirectory = directory

        ScrollingCaptureHUD.show(controller: self)

        // Grab the first frame immediately so the session always has content.
        captureFrame()
    }

    /// Captures the region as it looks right now.
    public func captureFrame() {
        guard isCapturing, let directory = workingDirectory else { return }

        Task { @MainActor in
            do {
                let result = try await ScreenCaptureEngine.shared.captureRegion(rect: region, on: screen)
                guard let data = ImageExporter.data(from: result.image, format: .png) else { return }

                let url = directory.appendingPathComponent(String(format: "frame-%03d.png", frameURLs.count))
                try data.write(to: url)
                frameURLs.append(url)
                frameCount = frameURLs.count
            } catch {
                NSLog("PixCap: scrolling frame failed — \(error.localizedDescription)")
            }
        }
    }

    /// Stitches the collected frames and ends the session.
    public func finish() {
        guard isCapturing else { return }
        isCapturing = false
        ScrollingCaptureHUD.hide()

        let frames = frameURLs
        let directory = workingDirectory
        let completion = self.completion
        self.completion = nil

        guard frames.count > 1 else {
            // A single frame needs no stitching.
            let image = frames.first.flatMap { NSImage(contentsOf: $0) }
            let result = image.map { CaptureResult(image: $0, mode: "scrolling") }
            finishSession(directory: directory, result: result, completion: completion)
            return
        }

        let outputURL = (directory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("stitched.png")

        DispatchQueue.global(qos: .userInitiated).async {
            let size = PixCapBridge.shared.stitchScrollFrames(
                paths: frames.map(\.path),
                outputPath: outputURL.path
            )

            let image = size != nil ? NSImage(contentsOf: outputURL) : nil
            let result = image.map { CaptureResult(image: $0, mode: "scrolling") }

            DispatchQueue.main.async {
                self.finishSession(directory: directory, result: result, completion: completion)
            }
        }
    }

    public func cancel() {
        isCapturing = false
        ScrollingCaptureHUD.hide()
        let completion = self.completion
        self.completion = nil
        finishSession(directory: workingDirectory, result: nil, completion: completion)
    }

    private func finishSession(
        directory: URL?,
        result: CaptureResult?,
        completion: ((CaptureResult?) -> Void)?
    ) {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        workingDirectory = nil
        frameURLs = []
        frameCount = 0
        completion?(result)
    }

    private func cleanUp() {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
    }
}

/// On-screen guidance and controls for a scrolling capture session.
@available(macOS 14.0, *)
struct ScrollingCaptureHUDView: View {
    @ObservedObject var controller: ScrollingCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                Text("Scrolling capture")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(controller.frameCount) frames")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Text("Scroll the window a little, then press Capture Frame. Overlapping frames stitch best.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Capture Frame") { controller.captureFrame() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Finish") { controller.finish() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

@available(macOS 14.0, *)
enum ScrollingCaptureHUD {
    private static var panel: NSPanel?

    static func show(controller: ScrollingCaptureController) {
        hide()

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .statusBar
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.isMovableByWindowBackground = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep the HUD out of the frames being stitched.
        created.sharingType = .none
        created.contentView = NSHostingView(rootView: ScrollingCaptureHUDView(controller: controller))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            created.setFrameOrigin(NSPoint(x: frame.maxX - 350, y: frame.midY))
        }

        created.orderFrontRegardless()
        panel = created
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
