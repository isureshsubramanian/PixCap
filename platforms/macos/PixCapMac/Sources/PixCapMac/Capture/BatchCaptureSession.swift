import Foundation
import AppKit
import SwiftUI
import PDFKit

/// Collects a run of captures, then exports them together.
///
/// Built for the workflow Reddit research kept surfacing: QA testers and
/// technical writers taking twenty shots in sequence, who do not want twenty
/// editor windows and twenty save dialogs.
@available(macOS 14.0, *)
public final class BatchCaptureSession: ObservableObject {
    public static let shared = BatchCaptureSession()

    @Published public private(set) var captures: [CaptureResult] = []
    @Published public private(set) var isActive = false
    @Published public private(set) var status: String?

    private init() {}

    public var count: Int { captures.count }

    public func begin() {
        captures.removeAll()
        status = nil
        isActive = true
        BatchCaptureHUD.show(session: self)
    }

    /// Adds a capture to the run. Returns false when no batch is in progress.
    @discardableResult
    public func add(_ result: CaptureResult) -> Bool {
        guard isActive else { return false }
        captures.append(result)
        status = nil
        return true
    }

    public func remove(at index: Int) {
        guard captures.indices.contains(index) else { return }
        captures.remove(at: index)
    }

    public func cancel() {
        captures.removeAll()
        isActive = false
        status = nil
        BatchCaptureHUD.hide()
    }

    public func finish() {
        isActive = false
        BatchCaptureHUD.hide()
    }

    // MARK: - Export

    /// Writes every capture into a folder chosen by the user.
    public func exportToFolder() {
        guard !captures.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(captures.count) captures"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let format = Settings.exportFormat
        var written = 0

        for (index, capture) in captures.enumerated() {
            let name = PixCapBridge.shared.resolveFilename(
                pattern: Settings.namingPattern,
                mode: capture.mode,
                appName: capture.appName,
                windowTitle: capture.windowTitle,
                width: Int(capture.image.size.width),
                height: Int(capture.image.size.height),
                counter: index + 1
            )

            // Batches are usually reviewed in order, so a numeric prefix keeps
            // them sorted regardless of what the naming pattern produces.
            let prefixed = String(format: "%03d-%@", index + 1, name)
            let url = directory.appendingPathComponent("\(prefixed).\(format.fileExtension)")

            if let data = ImageExporter.data(from: capture.image, format: format) {
                do {
                    try data.write(to: url)
                    written += 1
                } catch {
                    NSLog("PixCap: batch export failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        status = "Exported \(written) of \(captures.count) to \(directory.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// Writes every capture into a single multi-page PDF.
    public func exportToPDF() {
        guard !captures.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "PixCap-Batch.pdf"
        panel.message = "Save \(captures.count) captures as one PDF"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document = PDFDocument()

        for (index, capture) in captures.enumerated() {
            guard let page = PDFPage(image: capture.image) else { continue }
            document.insert(page, at: index)
        }

        if document.write(to: url) {
            status = "Wrote \(document.pageCount) pages to \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            status = "Could not write the PDF"
        }
    }
}

@available(macOS 14.0, *)
struct BatchCaptureHUDView: View {
    @ObservedObject var session: BatchCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right")
                Text("Batch capture")
                    .font(.headline)
                Spacer()
                Text("\(session.count)")
                    .font(.system(.title3, design: .rounded).bold())
                    .monospacedDigit()
            }

            Text("Each capture joins the batch instead of opening the editor. Export them together when you are done.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !session.captures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(session.captures.enumerated()), id: \.offset) { index, capture in
                            Image(nsImage: capture.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 54, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        session.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(1)
                                }
                        }
                    }
                }
                .frame(height: 44)
            }

            if let status = session.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Export Folder…") { session.exportToFolder() }
                    .disabled(session.captures.isEmpty)
                Button("Export PDF…") { session.exportToPDF() }
                    .disabled(session.captures.isEmpty)
                Spacer()
                Button("Done") { session.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

@available(macOS 14.0, *)
enum BatchCaptureHUD {
    private static var panel: NSPanel?

    static func show(session: BatchCaptureSession) {
        hide()

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
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
        // The HUD must stay out of the captures it is collecting.
        created.sharingType = .none
        created.contentView = NSHostingView(rootView: BatchCaptureHUDView(session: session))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            created.setFrameOrigin(NSPoint(x: frame.maxX - 390, y: frame.maxY - 260))
        }

        created.orderFrontRegardless()
        panel = created
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
