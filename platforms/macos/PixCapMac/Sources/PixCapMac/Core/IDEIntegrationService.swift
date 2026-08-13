import Foundation
import AppKit

/// Detects installed IDEs and whether the PixCap integration is present in them.
///
/// This replaced hardcoded status labels that claimed the VS Code extension was
/// "Active" and the JetBrains plugin was "Not Found" regardless of what was
/// actually on disk.
public enum IDEIntegrationService {

    public struct InstalledIDE: Identifiable {
        /// Product name as JetBrains writes it, e.g. `Rider`, `RustRover`.
        public let product: String
        /// Version suffix from the config directory, e.g. `2026.2`.
        public let version: String
        /// Directory holding third-party plugins for this install.
        public let pluginsDirectory: URL
        public let pluginInstalled: Bool

        public var id: String { "\(product)\(version)" }
        public var displayName: String { "\(product) \(version)" }
    }

    public enum EditorStatus {
        /// The editor itself was not found.
        case editorMissing
        /// Editor present, PixCap integration not installed.
        case notInstalled
        /// Editor present with the PixCap integration installed.
        case installed(version: String?)

        public var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    // MARK: - JetBrains

    /// JetBrains IDEs found via their configuration directories.
    ///
    /// The config directory is the reliable signal: Toolbox installs the apps
    /// under `~/Applications`, not `/Applications`, so scanning app folders
    /// alone misses them.
    public static func jetBrainsIDEs() -> [InstalledIDE] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("JetBrains", isDirectory: true)

        guard let root,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return []
        }

        // Product directories look like "Rider2026.2"; skip Toolbox's own
        // bookkeeping folders (Toolbox, Local, consentOptions, …).
        let pattern = try? NSRegularExpression(pattern: "^([A-Za-z]+)(\\d{4}\\.\\d+)$")

        return entries.compactMap { url -> InstalledIDE? in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern?.firstMatch(in: name, range: range),
                  match.numberOfRanges == 3,
                  let productRange = Range(match.range(at: 1), in: name),
                  let versionRange = Range(match.range(at: 2), in: name) else {
                return nil
            }

            let plugins = url.appendingPathComponent("plugins", isDirectory: true)
            return InstalledIDE(
                product: String(name[productRange]),
                version: String(name[versionRange]),
                pluginsDirectory: plugins,
                pluginInstalled: containsPixCapPlugin(plugins)
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private static func containsPixCapPlugin(_ pluginsDirectory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return entries.contains { $0.lastPathComponent.lowercased().contains("pixcap") }
    }

    // MARK: - VS Code

    /// Extension directories for VS Code and its variants.
    private static var vsCodeExtensionRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions"),
            home.appendingPathComponent(".cursor/extensions")
        ]
    }

    public static func vsCodeStatus() -> EditorStatus {
        let roots = vsCodeExtensionRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else { return .editorMissing }

        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }

            // VS Code installs extensions as "publisher.name-version".
            if let match = entries.first(where: {
                $0.lastPathComponent.lowercased().hasPrefix("pixcap.pixcap-vscode")
            }) {
                let name = match.lastPathComponent
                let version = name.split(separator: "-").last.map(String.init)
                return .installed(version: version)
            }
        }

        return .notInstalled
    }

    // MARK: - CLI

    /// Whether the `pixcap` CLI is on the user's PATH.
    public static func cliInstalled() -> Bool {
        let candidates = ["/usr/local/bin/pixcap", "/opt/homebrew/bin/pixcap"]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Path to the CLI built in this checkout, when present.
    public static func builtCLIPath() -> String? {
        let candidates = [
            "target/release/pixcap",
            "target/debug/pixcap"
        ]

        // Walk up from the app bundle to find the repository checkout.
        var directory = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            for candidate in candidates {
                let path = directory.appendingPathComponent(candidate).path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}
