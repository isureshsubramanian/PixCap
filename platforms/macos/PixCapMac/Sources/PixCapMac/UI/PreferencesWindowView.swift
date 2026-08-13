import SwiftUI
import Cocoa

/// PixCap Settings.
///
/// Follows the macOS System Settings pattern set out in ADR-001 §4.2: a
/// sidebar of tinted glyph tiles, inset grouped cards in the detail pane, a
/// search field that filters individual settings, and one typography scale.
@available(macOS 14.0, *)
public struct PreferencesWindowView: View {
    @StateObject private var store = SettingsStore()
    @State private var selection: SettingCategory?
    @State private var query: String = ""

    private let categories = SettingsCatalog.categories

    public init() {
        _selection = State(initialValue: SettingsCatalog.categories.first)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 880, idealWidth: 940, minHeight: 620, idealHeight: 680)
        .onChange(of: query) { _, value in
            // Jump to the first category with a hit so results are visible at once.
            guard !value.isEmpty else { return }
            let matches = matchingCategories
            if let current = selection, matches.contains(current) { return }
            selection = matches.first
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(matchingCategories) { category in
                NavigationLink(value: category) {
                    HStack(spacing: 10) {
                        glyph(for: category)
                        Text(category.title)
                            .font(SettingsType.sidebarItem)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                .tag(category)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 208, ideal: 216, max: 260)
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
    }

    /// Rounded tinted tile, as macOS System Settings uses.
    private func glyph(for category: SettingCategory) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(category.tint.gradient)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    /// Categories that still contain a matching row.
    private var matchingCategories: [SettingCategory] {
        guard !query.isEmpty else { return categories }
        return categories.filter { !$0.filtered(by: query).isEmpty }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let category = selection ?? matchingCategories.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(category.title)
                        .font(SettingsType.categoryTitle)
                        .padding(.bottom, 2)

                    if let message = store.message {
                        Label(message, systemImage: "info.circle")
                            .font(SettingsType.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let groups = category.filtered(by: query)

                    ForEach(groups) { group in
                        if isFullWidth(group) {
                            fullWidthPane(for: group)
                        } else {
                            SettingGroupView(group: group, store: store)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No settings match",
                systemImage: "magnifyingglass",
                description: Text("Try a different search term.")
            )
        }
    }

    /// Whether a group is a single bespoke pane rather than a list of rows.
    private func isFullWidth(_ group: SettingGroup) -> Bool {
        guard group.items.count == 1, case .custom(let id) = group.items[0].control else { return false }
        return ["hotkeys", "ide", "about"].contains(id)
    }

    @ViewBuilder private func fullWidthPane(for group: SettingGroup) -> some View {
        if case .custom(let id) = group.items[0].control {
            switch id {
            case "hotkeys": HotkeysPane()
            case "ide": IntegrationsPane()
            case "about": AboutPane()
            default: EmptyView()
            }
        }
    }
}

@available(macOS 14.0, *)
public final class PreferencesWindowController {
    private static var window: NSWindow?

    public static func openPreferences() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "PixCap Settings"
            win.contentViewController = NSHostingController(rootView: PreferencesWindowView())
            win.center()
            win.minSize = NSSize(width: 880, height: 620)
            win.isReleasedWhenClosed = false
            window = win
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func closeWindow() {
        window?.close()
    }
}
