import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A Preferences row that records a real global shortcut.
@available(macOS 14.0, *)
public struct HotkeyRecorderRow: View {
    public let action: HotkeyAction

    @State private var binding: HotkeyBinding?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var warning: String?

    public init(action: HotkeyAction) {
        self.action = action
        self._binding = State(initialValue: HotkeyManager.shared.binding(for: action))
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.body)
                    .lineLimit(1)
                if let warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                } else if HotkeyManager.shared.conflicted.contains(action) {
                    Text("Already used by the system or another app")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 92)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press a key combination, or ⎋ to cancel" : "Click to record a shortcut")

            Button {
                HotkeyManager.shared.resetToDefault(action)
                binding = HotkeyManager.shared.binding(for: action)
                warning = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Restore default")
        }
        .padding(.vertical, 3)
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Recording…" }
        return binding?.displayString ?? "Not set"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        warning = nil

        // Swallow key events while recording so they do not reach the UI.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
            return
        case kVK_Delete, kVK_ForwardDelete:
            HotkeyManager.shared.setBinding(nil, for: action)
            binding = nil
            stopRecording()
            return
        default:
            break
        }

        let candidate = HotkeyBinding(keyCode: event.keyCode, modifiers: event.modifierFlags)

        guard candidate.isValid else {
            warning = "Add ⌘, ⌥, ⌃, or ⇧ to make a global shortcut"
            return
        }

        if let clash = HotkeyManager.shared.conflictingAction(for: candidate, excluding: action) {
            warning = "Already assigned to \(clash.title)"
            return
        }

        HotkeyManager.shared.setBinding(candidate, for: action)
        binding = candidate
        warning = HotkeyManager.shared.conflicted.contains(action)
            ? "The system rejected this shortcut — try another"
            : nil
        stopRecording()
    }
}
