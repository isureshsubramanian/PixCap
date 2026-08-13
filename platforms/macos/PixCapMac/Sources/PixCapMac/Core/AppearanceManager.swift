import AppKit

/// Applies the appearance preferences that affect the running app.
public enum AppearanceManager {

    /// Set by the AppDelegate so menu bar style changes reach the status item.
    public static var onMenuBarStyleChange: (() -> Void)?

    /// Applies every appearance preference. Call at launch and after a change.
    public static func applyAll() {
        applyColorScheme()
        onMenuBarStyleChange?()
    }

    /// Overrides the app's appearance, or follows the system when set to System.
    public static func applyColorScheme() {
        let appearance: NSAppearance?

        switch Settings.string(SettingsKey.colorScheme, default: "System") {
        case "Dark":
            appearance = NSAppearance(named: .darkAqua)
        case "Light":
            appearance = NSAppearance(named: .aqua)
        default:
            appearance = nil // follow the system
        }

        // Must run on the main thread: this repaints every open window.
        if Thread.isMainThread {
            NSApp?.appearance = appearance
        } else {
            DispatchQueue.main.async { NSApp?.appearance = appearance }
        }
    }

    public enum MenuBarIconStyle: String {
        case iconOnly = "Icon Only"
        case iconAndText = "Icon + Text"
        case hidden = "Hidden"
    }

    public static var menuBarIconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: Settings.string(SettingsKey.menuBarIconStyle, default: "Icon Only")) ?? .iconOnly
    }
}
