import SwiftUI
import Cocoa
import ScreenCaptureKit

/// Full-screen countdown shown before a self-timer capture.
@available(macOS 14.0, *)
public final class CountdownOverlayController {
    private static var panel: NSPanel?
    private static var timer: Timer?
    private static var escapeMonitor: Any?

    public static func start(seconds: Double, completion: @escaping () -> Void) {
        cancel()

        var remaining = Int(seconds.rounded())
        guard remaining > 0 else { return completion() }

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .screenSaver
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.sharingType = .none

        let view = CountdownView(value: remaining)
        created.contentView = NSHostingView(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.frame
            created.setFrameOrigin(NSPoint(x: frame.midX - 90, y: frame.midY - 90))
        }
        created.orderFrontRegardless()
        panel = created

        // A timed capture is the easiest one to start by accident, so Escape
        // has to stop it. The panel ignores mouse events and never takes key
        // focus, so this needs an event monitor rather than a key handler.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53 else { return event }
            cancel()
            return nil
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            remaining -= 1
            if remaining <= 0 {
                cancel()
                completion()
            } else {
                created.contentView = NSHostingView(rootView: CountdownView(value: remaining))
            }
        }
    }

    public static func cancel() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

@available(macOS 14.0, *)
private struct CountdownView: View {
    let value: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.65))
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()

                Text("esc to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: 180, height: 180)
    }
}

/// Lets the user pick which on-screen window to capture.
@available(macOS 14.0, *)
public final class WindowPickerController {
    private static var window: NSWindow?

    public static func present(windows: [SCWindow], completion: @escaping (CGWindowID?) -> Void) {
        let entries = windows.map {
            WindowEntry(
                id: $0.windowID,
                appName: $0.owningApplication?.applicationName ?? "Unknown",
                title: $0.title ?? "Untitled",
                size: $0.frame.size
            )
        }

        let view = WindowPickerView(entries: entries) { selection in
            window?.close()
            window = nil
            completion(selection)
        }

        let picker = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        picker.title = "Choose a Window"
        picker.contentViewController = NSHostingController(rootView: view)
        picker.center()
        picker.isReleasedWhenClosed = false
        picker.sharingType = .none
        window = picker

        picker.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@available(macOS 14.0, *)
struct WindowEntry: Identifiable {
    let id: CGWindowID
    let appName: String
    let title: String
    let size: CGSize
}

@available(macOS 14.0, *)
struct WindowPickerView: View {
    let entries: [WindowEntry]
    let completion: (CGWindowID?) -> Void

    @State private var selection: CGWindowID?

    var body: some View {
        VStack(spacing: 0) {
            List(entries, selection: $selection) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "macwindow")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.appName).font(.body).lineLimit(1)
                        Text(entry.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(Int(entry.size.width))×\(Int(entry.size.height))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .tag(entry.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { completion(entry.id) }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Capture") { completion(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(10)
        }
    }
}
