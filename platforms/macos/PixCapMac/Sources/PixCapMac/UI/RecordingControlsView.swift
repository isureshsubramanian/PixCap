import SwiftUI
import Cocoa

/// Floating recorder controls: elapsed time, pause/resume, stop.
@available(macOS 14.0, *)
public struct RecordingControlsView: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    let onStop: () -> Void

    public var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recorder.isPaused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(recorder.isPaused ? 1 : 0.9)

            Text(timeString)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)

            Divider().frame(height: 18)

            Button(action: recorder.togglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(recorder.isPaused ? "Resume" : "Pause")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Stop and save")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@available(macOS 14.0, *)
public enum RecordingControlsController {
    private static var panel: NSPanel?

    public static func show(onStop: @escaping () -> Void) {
        hide()

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 46),
            styleMask: [.nonactivatingPanel, .borderless],
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
        // The controls must never appear in the recording they control.
        created.sharingType = .none

        created.contentView = NSHostingView(rootView: RecordingControlsView(onStop: onStop))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            created.setFrameOrigin(NSPoint(x: frame.midX - 115, y: frame.minY + 40))
        }

        created.orderFrontRegardless()
        panel = created
    }

    public static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
