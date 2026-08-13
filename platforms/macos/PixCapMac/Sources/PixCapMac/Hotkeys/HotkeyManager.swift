import Foundation
import AppKit
import Carbon.HIToolbox

/// A recorded key combination.
public struct HotkeyBinding: Codable, Equatable {
    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, already masked to the device-independent flags.
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Carbon modifier mask used by `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Human-readable form, e.g. `⌥⇧A`.
    public var displayString: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + HotkeyBinding.keyName(for: keyCode)
    }

    /// A binding is only usable as a global hotkey if it carries a modifier.
    public var isValid: Bool {
        !modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }

        // Translate through the active keyboard layout so non-US layouts label correctly.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let keyboardLayout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]
}

/// Every globally bindable command.
public enum HotkeyAction: String, CaseIterable, Identifiable {
    case captureArea
    case captureFullscreen
    case captureWindow
    case selfTimer
    case captureAreaAndCopy
    case captureAreaAndSave
    case openHistory
    case restoreLastCapture
    case toggleRecording
    case captureText
    case scrollingCapture
    case pinToScreen
    case togglePins
    case batchCapture

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .selfTimer: return "Self-Timer Capture"
        case .captureAreaAndCopy: return "Capture Area & Copy"
        case .captureAreaAndSave: return "Capture Area & Save"
        case .openHistory: return "Open Screenshot History"
        case .restoreLastCapture: return "Reopen Last Capture"
        case .toggleRecording: return "Start / Stop Recording"
        case .captureText: return "Capture Text (OCR)"
        case .scrollingCapture: return "Scrolling Capture"
        case .pinToScreen: return "Pin Region to Screen"
        case .togglePins: return "Show / Hide All Pins"
        case .batchCapture: return "Start / Finish Batch Capture"
        }
    }

    public var section: String {
        switch self {
        case .captureArea, .captureFullscreen, .captureWindow, .selfTimer,
             .captureAreaAndCopy, .captureAreaAndSave, .scrollingCapture:
            return "Screenshots"
        case .toggleRecording:
            return "Recording"
        case .openHistory, .restoreLastCapture, .captureText, .pinToScreen, .togglePins, .batchCapture:
            return "Utilities"
        }
    }

    /// Defaults avoid ⇧⌘3/4/5, which macOS reserves for its own screenshot tools.
    public var defaultBinding: HotkeyBinding {
        switch self {
        case .captureArea: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option, .shift])
        case .captureFullscreen: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_F), modifiers: [.option, .shift])
        case .captureWindow: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option, .shift])
        case .selfTimer: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_T), modifiers: [.option, .shift])
        case .captureAreaAndCopy: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.option, .shift])
        case .captureAreaAndSave: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_S), modifiers: [.option, .shift])
        case .openHistory: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_H), modifiers: [.option, .shift])
        case .restoreLastCapture: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_R), modifiers: [.option, .shift])
        case .toggleRecording: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option, .shift])
        case .captureText: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_O), modifiers: [.option, .shift])
        case .scrollingCapture: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_L), modifiers: [.option, .shift])
        case .pinToScreen: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_P), modifiers: [.option, .shift])
        case .togglePins: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: [.option, .shift])
        case .batchCapture: return HotkeyBinding(keyCode: UInt16(kVK_ANSI_B), modifiers: [.option, .shift])
        }
    }

    var defaultsKey: String { "pixcapHotkey_\(rawValue)" }
}

/// Registers system-wide hotkeys through Carbon and dispatches them to handlers.
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private var handlers: [HotkeyAction: () -> Void] = [:]
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// Actions whose binding was rejected by the system (usually already taken).
    public private(set) var conflicted: Set<HotkeyAction> = []

    private static let signature: OSType = 0x50584350 // 'PXCP'

    private init() {}

    // MARK: - Bindings

    public func binding(for action: HotkeyAction) -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else {
            return action.defaultBinding
        }
        // An empty blob means the user deliberately cleared the shortcut.
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    public func setBinding(_ binding: HotkeyBinding?, for action: HotkeyAction) {
        if let binding, let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.set(Data(), forKey: action.defaultsKey)
        }
        reregister(action)
    }

    public func resetToDefault(_ action: HotkeyAction) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        reregister(action)
    }

    /// Another action already using `binding`, if any.
    public func conflictingAction(for binding: HotkeyBinding, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && self.binding(for: $0) == binding }
    }

    // MARK: - Registration

    /// Installs handlers and registers every stored binding. Call once at launch.
    public func registerAll(handlers: [HotkeyAction: () -> Void]) {
        self.handlers = handlers
        installEventHandlerIfNeeded()
        HotkeyAction.allCases.forEach(reregister)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                HotkeyManager.shared.handle(rawID: hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    private func reregister(_ action: HotkeyAction) {
        if let existing = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(existing)
        }
        conflicted.remove(action)

        guard let binding = binding(for: action), binding.isValid,
              let index = HotkeyAction.allCases.firstIndex(of: action) else { return }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(index))
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        if status == noErr, let reference {
            registrations[action] = reference
        } else {
            conflicted.insert(action)
            NSLog("PixCap: could not register hotkey \(binding.displayString) for \(action.rawValue) (status \(status))")
        }
    }

    private func handle(rawID: UInt32) {
        let actions = HotkeyAction.allCases
        guard Int(rawID) < actions.count else { return }
        let action = actions[Int(rawID)]
        DispatchQueue.main.async { [weak self] in
            self?.handlers[action]?()
        }
    }
}
