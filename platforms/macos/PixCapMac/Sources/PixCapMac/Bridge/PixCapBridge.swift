import Foundation
import AppKit

// C-ABI declarations for Rust FFI functions
@_silgen_name("pixcap_render_snippet")
func pixcap_render_snippet(_ code: UnsafePointer<CChar>?, _ language: UnsafePointer<CChar>?, _ syntax_theme: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_free_string")
func pixcap_free_string(_ s: UnsafeMutablePointer<CChar>?)

@_silgen_name("pixcap_theme_presets_json")
func pixcap_theme_presets_json() -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_resolve_filename")
func pixcap_resolve_filename(_ pattern: UnsafePointer<CChar>?, _ mode: UnsafePointer<CChar>?, _ app: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?, _ width: UInt32, _ height: UInt32, _ counter: UInt32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_default_naming_pattern")
func pixcap_default_naming_pattern() -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_history_open")
func pixcap_history_open(_ path: UnsafePointer<CChar>?) -> OpaquePointer?

@_silgen_name("pixcap_history_close")
func pixcap_history_close(_ handle: OpaquePointer?)

@_silgen_name("pixcap_history_insert")
func pixcap_history_insert(_ handle: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> Int64

@_silgen_name("pixcap_history_recent")
func pixcap_history_recent(_ handle: OpaquePointer?, _ limit: Int64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_history_search")
func pixcap_history_search(_ handle: OpaquePointer?, _ query: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_history_delete")
func pixcap_history_delete(_ handle: OpaquePointer?, _ id: Int64) -> Int32

@_silgen_name("pixcap_history_toggle_favorite")
func pixcap_history_toggle_favorite(_ handle: OpaquePointer?, _ id: Int64) -> Int32

@_silgen_name("pixcap_syntax_languages_json")
func pixcap_syntax_languages_json() -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_syntax_themes_json")
func pixcap_syntax_themes_json() -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_document_write")
func pixcap_document_write(_ json: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?) -> Int32

@_silgen_name("pixcap_document_read")
func pixcap_document_read(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_document_sidecar_path")
func pixcap_document_sidecar_path(_ imagePath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("pixcap_stitch_scroll_frames")
func pixcap_stitch_scroll_frames(_ pathsJSON: UnsafePointer<CChar>?, _ outputPath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

/// Takes ownership of a Rust-allocated C string, converting and freeing it.
private func consumeRustString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { pixcap_free_string(pointer) }
    return String(cString: pointer)
}

// MARK: - Shared background presets

/// Mirrors `pixcap_core::themes::BackgroundFill`.
public enum BackgroundFill: Decodable {
    case gradient(angle: Double, stops: [(position: Double, hex: String)])
    case solid(hex: String)
    case transparent
    case glassmorphism(blurRadius: Double, hex: String, opacity: Double)

    private enum CodingKeys: String, CodingKey {
        case Gradient, Solid, Transparent, Glassmorphism
    }

    private enum GradientKeys: String, CodingKey {
        case angle_deg, stops
    }

    private enum GlassKeys: String, CodingKey {
        case blur_radius, bg_hex, opacity
    }

    public init(from decoder: Decoder) throws {
        // Serde encodes unit variants as a bare string, data variants as a single-key object.
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            if name == "Transparent" {
                self = .transparent
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.Gradient) {
            let gradient = try container.nestedContainer(keyedBy: GradientKeys.self, forKey: .Gradient)
            let angle = try gradient.decode(Double.self, forKey: .angle_deg)
            var stopsContainer = try gradient.nestedUnkeyedContainer(forKey: .stops)
            var stops: [(position: Double, hex: String)] = []
            while !stopsContainer.isAtEnd {
                var pair = try stopsContainer.nestedUnkeyedContainer()
                let position = try pair.decode(Double.self)
                let hex = try pair.decode(String.self)
                stops.append((position, hex))
            }
            self = .gradient(angle: angle, stops: stops)
        } else if container.contains(.Solid) {
            self = .solid(hex: try container.decode(String.self, forKey: .Solid))
        } else if container.contains(.Glassmorphism) {
            let glass = try container.nestedContainer(keyedBy: GlassKeys.self, forKey: .Glassmorphism)
            self = .glassmorphism(
                blurRadius: try glass.decode(Double.self, forKey: .blur_radius),
                hex: try glass.decode(String.self, forKey: .bg_hex),
                opacity: try glass.decode(Double.self, forKey: .opacity)
            )
        } else {
            self = .transparent
        }
    }
}

/// Mirrors `pixcap_core::themes::BackgroundPreset`.
public struct BackgroundPreset: Decodable, Identifiable {
    public let id: String
    public let name: String
    public let fill: BackgroundFill
}

/// Mirrors `pixcap_core::syntax::LanguageInfo`.
public struct SyntaxLanguage: Decodable, Identifiable, Hashable {
    public let name: String
    /// Identifier passed back when highlighting, e.g. "rs".
    public let token: String
    public let extensions: [String]

    public var id: String { token }
}

// MARK: - History records

/// Mirrors `pixcap_core::history::ScreenshotRecord`.
public struct ScreenshotRecord: Codable, Identifiable, Equatable {
    public var id: Int64
    public var filepath: String
    public var thumbnail_path: String?
    public var captured_at: String
    public var capture_mode: String?
    public var width: Int64?
    public var height: Int64?
    public var ocr_text: String?
    public var tags: String?
    public var is_favorited: Bool

    public var fileURL: URL { URL(fileURLWithPath: filepath) }

    public var capturedDate: Date {
        ISO8601DateFormatter().date(from: captured_at) ?? Date.distantPast
    }
}

// MARK: - Bridge

public final class PixCapBridge {
    public static let shared = PixCapBridge()

    private init() {}

    /// Calls Rust FFI core to render a code snippet to SVG string
    public func renderSnippet(code: String, language: String, theme: String = "base16-ocean.dark") -> String? {
        code.withCString { codePtr in
            language.withCString { langPtr in
                theme.withCString { themePtr in
                    consumeRustString(pixcap_render_snippet(codePtr, langPtr, themePtr))
                }
            }
        }
    }

    /// The background preset catalogue defined once in the Rust core.
    public private(set) lazy var backgroundPresets: [BackgroundPreset] = {
        guard let json = consumeRustString(pixcap_theme_presets_json()),
              let data = json.data(using: .utf8),
              let presets = try? JSONDecoder().decode([BackgroundPreset].self, from: data) else {
            return []
        }
        return presets
    }()

    public func preset(id: String) -> BackgroundPreset? {
        backgroundPresets.first { $0.id == id }
    }

    /// Expands a file naming pattern (`{date}`, `{app}`, `{counter}`, …) via the Rust core.
    public func resolveFilename(
        pattern: String,
        mode: String,
        appName: String?,
        windowTitle: String?,
        width: Int,
        height: Int,
        counter: Int
    ) -> String {
        pattern.withCString { patternPtr in
            mode.withCString { modePtr in
                withOptionalCString(appName) { appPtr in
                    withOptionalCString(windowTitle) { titlePtr in
                        consumeRustString(pixcap_resolve_filename(
                            patternPtr,
                            modePtr,
                            appPtr,
                            titlePtr,
                            UInt32(max(0, width)),
                            UInt32(max(0, height)),
                            UInt32(max(0, counter))
                        )) ?? pattern
                    }
                }
            }
        }
    }

    public var defaultNamingPattern: String {
        consumeRustString(pixcap_default_naming_pattern()) ?? "PixCap_{date}_{time}_{counter}"
    }

    /// Every language the Rust syntax engine can highlight.
    ///
    /// Loaded from the core rather than hardcoded, so the picker always offers
    /// exactly what the engine supports.
    public private(set) lazy var syntaxLanguages: [SyntaxLanguage] = {
        guard let json = consumeRustString(pixcap_syntax_languages_json()),
              let data = json.data(using: .utf8),
              let languages = try? JSONDecoder().decode([SyntaxLanguage].self, from: data) else {
            return []
        }
        return languages
    }()

    /// Syntax colour themes bundled with the engine.
    public private(set) lazy var syntaxThemes: [String] = {
        guard let json = consumeRustString(pixcap_syntax_themes_json()),
              let data = json.data(using: .utf8),
              let themes = try? JSONDecoder().decode([String].self, from: data) else {
            return ["base16-ocean.dark"]
        }
        return themes
    }()

    // MARK: - Documents

    /// Sidecar path for an image, derived by the Rust core.
    public func sidecarPath(forImage path: String) -> String {
        path.withCString { consumeRustString(pixcap_document_sidecar_path($0)) }
            ?? path + ".pixcap.json"
    }

    /// Validates the document against the shared schema and writes it.
    public func writeDocument(json: String, to path: String) -> Bool {
        json.withCString { jsonPtr in
            path.withCString { pathPtr in
                pixcap_document_write(jsonPtr, pathPtr) == 0
            }
        }
    }

    /// Reads a document, returning JSON with any missing fields defaulted.
    public func readDocument(at path: String) -> String? {
        path.withCString { consumeRustString(pixcap_document_read($0)) }
    }

    // MARK: - Scrolling capture

    /// Stitches scrolling-capture frames into a single tall image.
    ///
    /// - Returns: the stitched pixel dimensions, or nil if stitching failed.
    public func stitchScrollFrames(paths: [String], outputPath: String) -> CGSize? {
        guard let pathsData = try? JSONEncoder().encode(paths),
              let pathsJSON = String(data: pathsData, encoding: .utf8) else {
            return nil
        }

        let result = pathsJSON.withCString { jsonPtr in
            outputPath.withCString { outPtr in
                consumeRustString(pixcap_stitch_scroll_frames(jsonPtr, outPtr))
            }
        }

        guard let result,
              let data = result.data(using: .utf8),
              let size = try? JSONDecoder().decode(StitchSize.self, from: data) else {
            return nil
        }

        return CGSize(width: size.width, height: size.height)
    }

    private struct StitchSize: Decodable {
        let width: Double
        let height: Double
    }

    private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }
}

// MARK: - History store

/// Serial-queue wrapper around the Rust SQLite history handle.
///
/// The underlying connection is not thread-safe, so every call is funnelled
/// through a single private queue.
public final class HistoryStore {
    public static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "app.pixcap.history")
    private var handle: OpaquePointer?

    private init() {
        let directory = PixCapPaths.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("history.sqlite").path
        handle = dbPath.withCString { pixcap_history_open($0) }
    }

    deinit {
        pixcap_history_close(handle)
    }

    @discardableResult
    public func insert(_ record: ScreenshotRecord) -> Int64 {
        queue.sync {
            guard let handle,
                  let data = try? JSONEncoder().encode(record),
                  let json = String(data: data, encoding: .utf8) else { return -1 }
            return json.withCString { pixcap_history_insert(handle, $0) }
        }
    }

    public func recent(limit: Int = 200) -> [ScreenshotRecord] {
        queue.sync {
            guard let handle else { return [] }
            return decode(consumeRustString(pixcap_history_recent(handle, Int64(limit))))
        }
    }

    public func search(_ query: String) -> [ScreenshotRecord] {
        queue.sync {
            guard let handle else { return [] }
            return decode(query.withCString { consumeRustString(pixcap_history_search(handle, $0)) })
        }
    }

    public func delete(id: Int64) {
        queue.sync {
            guard let handle else { return }
            _ = pixcap_history_delete(handle, id)
        }
    }

    public func toggleFavorite(id: Int64) {
        queue.sync {
            guard let handle else { return }
            _ = pixcap_history_toggle_favorite(handle, id)
        }
    }

    private func decode(_ json: String?) -> [ScreenshotRecord] {
        guard let json, let data = json.data(using: .utf8),
              let records = try? JSONDecoder().decode([ScreenshotRecord].self, from: data) else {
            return []
        }
        return records
    }
}

/// Canonical on-disk locations used by the app.
public enum PixCapPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PixCap", isDirectory: true)
    }

    public static var thumbnailDirectory: URL {
        supportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }
}
