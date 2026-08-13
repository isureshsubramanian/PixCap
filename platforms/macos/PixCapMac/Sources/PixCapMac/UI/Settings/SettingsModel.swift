import SwiftUI
import AppKit
import ServiceManagement

/// The settings catalogue, described as data.
///
/// Every row used to be hand-written SwiftUI with `.lineLimit(1)` applied to it,
/// which is why labels truncated and no two sections looked alike. Describing
/// settings as data gives one renderer, one visual language, and makes search
/// possible — you cannot search views, but you can search a catalogue.

// MARK: - Controls

public enum SettingControl {
    case toggle(key: String)
    case segmented(key: String, options: [String])
    case menu(key: String, options: [String])
    case slider(key: String, range: ClosedRange<Double>, unit: String = "")
    case stepper(key: String, range: ClosedRange<Int>)
    case color(key: String)
    case textField(key: String, placeholder: String)
    /// Rows that need bespoke views: hotkey recorders, IDE status, About, …
    case custom(id: String)
}

// MARK: - Items

public struct SettingItem: Identifiable {
    public let id: String
    public let title: String
    /// Explanatory line under the title. Wraps freely — never truncated.
    public let subtitle: String?
    public let control: SettingControl
    /// Extra search terms that are not in the title.
    public let keywords: [String]
    /// When set, the row is disabled and labelled with this reason.
    public let unavailable: String?

    public init(
        _ title: String,
        subtitle: String? = nil,
        control: SettingControl,
        keywords: [String] = [],
        unavailable: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
        self.keywords = keywords
        self.unavailable = unavailable

        switch control {
        case .toggle(let key), .segmented(let key, _), .menu(let key, _),
             .slider(let key, _, _), .stepper(let key, _), .color(let key),
             .textField(let key, _):
            self.id = key
        case .custom(let identifier):
            self.id = identifier
        }
    }

    /// Whether this row matches a search query.
    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if title.lowercased().contains(needle) { return true }
        if let subtitle, subtitle.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }
}

public struct SettingGroup: Identifiable {
    public let id = UUID()
    public let title: String?
    public let footer: String?
    public let items: [SettingItem]

    public init(_ title: String? = nil, footer: String? = nil, items: [SettingItem]) {
        self.title = title
        self.footer = footer
        self.items = items
    }
}

public struct SettingCategory: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let symbol: String
    /// Tint for the sidebar glyph tile, as in macOS System Settings.
    public let tint: Color
    public let groups: [SettingGroup]

    public static func == (lhs: SettingCategory, rhs: SettingCategory) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Groups reduced to rows matching `query`, dropping groups left empty.
    func filtered(by query: String) -> [SettingGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { $0.matches(query) }
            return items.isEmpty ? nil : SettingGroup(group.title, footer: group.footer, items: items)
        }
    }
}

// MARK: - Live store

/// Reads and writes settings, republishing so the UI updates, and runs the
/// side effects a few settings need.
@available(macOS 14.0, *)
public final class SettingsStore: ObservableObject {
    @Published public var message: String?

    public init() {}

    public func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { Settings.bool(key) },
            set: { [weak self] value in
                self?.objectWillChange.send()
                UserDefaults.standard.set(value, forKey: key)
                self?.applySideEffects(for: key)
            }
        )
    }

    public func stringBinding(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { Settings.string(key, default: fallback) },
            set: { [weak self] value in
                self?.objectWillChange.send()
                UserDefaults.standard.set(value, forKey: key)
                self?.applySideEffects(for: key)
            }
        )
    }

    public func doubleBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { Settings.double(key) },
            set: { [weak self] value in
                self?.objectWillChange.send()
                UserDefaults.standard.set(value, forKey: key)
            }
        )
    }

    public func intBinding(_ key: String) -> Binding<Int> {
        Binding(
            get: { Settings.int(key) },
            set: { [weak self] value in
                self?.objectWillChange.send()
                UserDefaults.standard.set(value, forKey: key)
            }
        )
    }

    public func colorBinding(_ key: String, fallback: NSColor = .systemRed) -> Binding<Color> {
        Binding(
            get: { Color(NSColor(hex: Settings.string(key)) ?? fallback) },
            set: { [weak self] value in
                self?.objectWillChange.send()
                UserDefaults.standard.set(NSColor(value).hexString, forKey: key)
            }
        )
    }

    /// Settings that must do something the moment they change.
    private func applySideEffects(for key: String) {
        switch key {
        case SettingsKey.colorScheme:
            AppearanceManager.applyColorScheme()
        case SettingsKey.menuBarIconStyle:
            AppearanceManager.applyAll()
        case SettingsKey.launchAtLogin:
            applyLaunchAtLogin(Settings.bool(key))
        default:
            break
        }
    }

    /// `SMAppService` needs a bundled app; report failure rather than silently ignoring it.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            UserDefaults.standard.set(!enabled, forKey: SettingsKey.launchAtLogin)
            message = "Launch at login needs the bundled PixCap app: \(error.localizedDescription)"
        }
    }

    /// Clears every PixCap preference after confirmation.
    public func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Every PixCap preference, including recorded shortcuts, returns to its default."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("pixcap") {
            defaults.removeObject(forKey: key)
        }
        Settings.registerDefaults()
        HotkeyAction.allCases.forEach { HotkeyManager.shared.resetToDefault($0) }
        AppearanceManager.applyAll()

        objectWillChange.send()
        message = "All settings restored to defaults."
    }

    public func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory

        if panel.runModal() == .OK, let url = panel.url {
            objectWillChange.send()
            UserDefaults.standard.set(url.path, forKey: SettingsKey.saveDirectory)
        }
    }
}
