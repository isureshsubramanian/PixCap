import SwiftUI
import AppKit

/// One typography scale for the whole settings window.
///
/// The old pane mixed `.headline`, `.body`, `.caption`, `.caption2`, and
/// monospaced fragments, so nothing lined up. These follow the macOS System
/// Settings scale: 13pt rows, 11pt secondary detail, 11pt semibold headers.
@available(macOS 14.0, *)
public enum SettingsType {
    public static let rowTitle = Font.system(size: 13)
    public static let rowSubtitle = Font.system(size: 11)
    public static let groupHeader = Font.system(size: 11, weight: .semibold)
    public static let groupFooter = Font.system(size: 11)
    public static let categoryTitle = Font.system(size: 22, weight: .bold)
    public static let sidebarItem = Font.system(size: 13)
    public static let value = Font.system(size: 11).monospacedDigit()
}

/// A settings row: title, optional wrapping subtitle, trailing control.
@available(macOS 14.0, *)
struct SettingRowView: View {
    let item: SettingItem
    @ObservedObject var store: SettingsStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SettingsType.rowTitle)
                    // No lineLimit: labels wrap instead of truncating.
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let unavailable = item.unavailable {
                    Label(unavailable, systemImage: "hammer")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control
                .disabled(item.unavailable != nil)
                .opacity(item.unavailable != nil ? 0.5 : 1)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private var control: some View {
        switch item.control {
        case .toggle(let key):
            Toggle("", isOn: store.boolBinding(key))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

        case .segmented(let key, let options):
            Picker("", selection: store.stringBinding(key, default: options.first ?? "")) {
                ForEach(options, id: \.self) { Text($0).font(SettingsType.rowTitle).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

        case .menu(let key, let options):
            Picker("", selection: store.stringBinding(key, default: options.first ?? "")) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

        case .slider(let key, let range, let unit):
            HStack(spacing: 8) {
                Slider(value: store.doubleBinding(key), in: range)
                    .frame(width: 150)
                Text("\(Int(store.doubleBinding(key).wrappedValue))\(unit)")
                    .font(SettingsType.value)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

        case .stepper(let key, let range):
            HStack(spacing: 8) {
                Text("\(store.intBinding(key).wrappedValue)")
                    .font(SettingsType.value)
                    .foregroundStyle(.secondary)
                Stepper("", value: store.intBinding(key), in: range)
                    .labelsHidden()
            }

        case .color(let key):
            ColorPicker("", selection: store.colorBinding(key), supportsOpacity: true)
                .labelsHidden()

        case .textField(let key, let placeholder):
            TextField(placeholder, text: store.stringBinding(key))
                .textFieldStyle(.roundedBorder)
                .font(SettingsType.rowTitle)
                .frame(width: 260)

        case .custom(let id):
            CustomSettingView(id: id, store: store)
        }
    }
}

/// A group of rows inside an inset card, with an optional header and footer.
@available(macOS 14.0, *)
struct SettingGroupView: View {
    let group: SettingGroup
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = group.title {
                Text(title.uppercased())
                    .font(SettingsType.groupHeader)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    SettingRowView(item: item, store: store)
                        .padding(.horizontal, 14)

                    if index < group.items.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            if let footer = group.footer {
                Text(footer)
                    .font(SettingsType.groupFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .padding(.top, 1)
            }
        }
    }
}

/// Rows that need bespoke views rather than a generic control.
@available(macOS 14.0, *)
struct CustomSettingView: View {
    let id: String
    @ObservedObject var store: SettingsStore

    var body: some View {
        switch id {
        case "resetAll":
            Button("Reset…") { store.resetAll() }

        case "saveDirectory":
            HStack(spacing: 8) {
                Text(Settings.saveDirectory.path)
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 240, alignment: .trailing)
                Button("Choose…") { store.chooseSaveDirectory() }
            }

        case "namingPreview":
            Text(namingPreview)
                .font(SettingsType.value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .trailing)

        case "backgroundPreset":
            Picker("", selection: store.stringBinding(SettingsKey.defaultBackgroundPreset, default: "azure-mesh")) {
                ForEach(PixCapBridge.shared.backgroundPresets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .labelsHidden()
            .frame(width: 150)

        default:
            EmptyView()
        }
    }

    private var namingPreview: String {
        PixCapBridge.shared.resolveFilename(
            pattern: Settings.namingPattern,
            mode: "area",
            appName: "Safari",
            windowTitle: "Example",
            width: 1920,
            height: 1080,
            counter: Settings.int(SettingsKey.captureCounter) + 1
        ) + "." + Settings.exportFormat.fileExtension
    }
}

// MARK: - Full-width custom panes

/// The shortcuts pane: real recorders grouped by section.
@available(macOS 14.0, *)
struct HotkeysPane: View {
    private let sections = ["Screenshots", "Recording", "Utilities"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections, id: \.self) { section in
                let actions = HotkeyAction.allCases.filter { $0.section == section }
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.uppercased())
                            .font(SettingsType.groupHeader)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                HotkeyRecorderRow(action: action)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 3)
                                if index < actions.count - 1 {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("EDITOR TOOLS")
                    .font(SettingsType.groupHeader)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                Text("Single keys, active while the editor window is focused.")
                    .font(SettingsType.groupFooter)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AnnotationTool.allCases) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: tool.symbolName)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(tool.title)
                                .font(SettingsType.rowSubtitle)
                            Spacer(minLength: 4)
                            Text(tool.shortcut)
                                .font(SettingsType.value)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

/// Detected editors, plugin state, and CLI status.
@available(macOS 14.0, *)
struct IntegrationsPane: View {
    @State private var jetBrains = IDEIntegrationService.jetBrainsIDEs()
    @State private var vsCode = IDEIntegrationService.vsCodeStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("VISUAL STUDIO CODE") {
                switch vsCode {
                case .installed(let version):
                    row(.green, "checkmark.circle.fill", "Extension installed\(version.map { " (\($0))" } ?? "")")
                case .notInstalled:
                    row(.orange, "exclamationmark.circle.fill", "VS Code found · PixCap extension not installed")
                case .editorMissing:
                    row(.secondary, "minus.circle", "VS Code not found")
                }
            }

            card("JETBRAINS IDES", footer: "The PixCap JetBrains plugin has not been built yet — only VS Code ships an extension today.") {
                if jetBrains.isEmpty {
                    row(.secondary, "minus.circle", "No JetBrains IDEs found")
                } else {
                    ForEach(jetBrains) { ide in
                        row(
                            ide.pluginInstalled ? .green : .orange,
                            ide.pluginInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            "\(ide.displayName) · \(ide.pluginInstalled ? "plugin installed" : "plugin not installed")"
                        )
                    }
                }
            }

            card("COMMAND LINE") {
                if IDEIntegrationService.cliInstalled() {
                    row(.green, "checkmark.circle.fill", "pixcap is on your PATH")
                } else if let built = IDEIntegrationService.builtCLIPath() {
                    row(.orange, "exclamationmark.circle.fill", "Built but not linked")
                    Text(built)
                        .font(SettingsType.value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    row(.secondary, "minus.circle", "Not built — run cargo build --release")
                }
            }
        }
        .onAppear {
            jetBrains = IDEIntegrationService.jetBrainsIDEs()
            vsCode = IDEIntegrationService.vsCodeStatus()
        }
    }

    private func row(_ color: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(SettingsType.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SettingsType.groupHeader)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            if let footer {
                Text(footer)
                    .font(SettingsType.groupFooter)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
    }
}

@available(macOS 14.0, *)
struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.top, 24)

            VStack(spacing: 4) {
                Text("PixCap").font(SettingsType.categoryTitle)
                Text("Version \(version) · Apple Silicon")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(.secondary)
            }

            Text("Screen capture, annotation, and code beautification with a shared Rust core. Everything runs on this Mac.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
