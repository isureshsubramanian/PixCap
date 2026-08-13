import SwiftUI
import Cocoa

/// Floating post-capture thumbnail with one-click follow-up actions.
@available(macOS 14.0, *)
public struct QuickAccessOverlayView: View {
    let result: CaptureResult
    let savedURL: URL?
    let closeAction: () -> Void

    @State private var status: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status ?? label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: closeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Image(nsImage: result.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 116)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .onTapGesture(perform: openEditor)
                // Drag the thumbnail straight into another app.
                .onDrag {
                    if let savedURL {
                        return NSItemProvider(contentsOf: savedURL) ?? NSItemProvider(object: result.image)
                    }
                    return NSItemProvider(object: result.image)
                }

            HStack(spacing: 6) {
                actionButton("Edit", systemImage: "wand.and.stars", action: openEditor)
                actionButton("Copy", systemImage: "doc.on.doc") {
                    ImageExporter.copyToClipboard(result.image)
                    flash("Copied to clipboard")
                }
                actionButton("Reveal", systemImage: "folder") {
                    guard let savedURL else { return flash("Not saved to disk") }
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                }
            }
        }
        .padding(12)
        .frame(width: 290, height: 200)
        .background(VisualEffectView().ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var label: String {
        let size = "\(Int(result.image.size.width)) × \(Int(result.image.size.height))"
        return savedURL.map { "\($0.lastPathComponent) · \(size)" } ?? size
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
    }

    private func openEditor() {
        EditorWindowController.openEditor(with: result.image, mode: result.mode)
        closeAction()
    }

    private func flash(_ message: String) {
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if status == message { status = nil }
        }
    }
}

@available(macOS 14.0, *)
public final class QuickAccessOverlayController {
    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    public static func show(result: CaptureResult, savedURL: URL?) {
        // A newer capture replaces the previous overlay and its pending timer.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = existingPanel()

        panel.contentView = NSHostingView(rootView: QuickAccessOverlayView(
            result: result,
            savedURL: savedURL,
            closeAction: dismiss
        ))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.minY + 20))
        }

        panel.orderFrontRegardless()

        if let delay = Settings.quickAccessDismissSeconds {
            let workItem = DispatchWorkItem { dismiss() }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    public static func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
    }

    private static func existingPanel() -> NSPanel {
        if let panel { return panel }

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 200),
            styleMask: [.nonactivatingPanel, .utilityWindow, .borderless],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .floating
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep the overlay out of subsequent captures.
        created.sharingType = .none

        panel = created
        return created
    }
}

@available(macOS 14.0, *)
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
