import Foundation
import AppKit

/// Canonical `UserDefaults` keys.
///
/// Preferences UI and the capture pipeline both read from here so a toggle in
/// Settings always drives the behaviour it names.
public enum SettingsKey {
    // General & appearance
    public static let launchAtLogin = "pixcapLaunchAtLogin"
    public static let menuBarIconStyle = "pixcapMenuBarIconStyle"
    public static let colorScheme = "pixcapColorScheme"
    public static let playCaptureSound = "pixcapPlayCaptureSound"
    public static let showNotifications = "pixcapShowNotifications"
    public static let checkForUpdates = "pixcapCheckForUpdates"

    // Capture behaviour
    public static let defaultCaptureMode = "pixcapDefaultCaptureMode"
    public static let rememberRegion = "pixcapRememberRegion"
    public static let showMagnifier = "pixcapShowMagnifier"
    public static let captureWindowShadow = "pixcapCaptureWindowShadow"
    public static let freezeScreen = "pixcapFreezeScreen"
    public static let hideDesktopIcons = "pixcapHideDesktopIcons"
    public static let selfTimerDuration = "pixcapSelfTimerDuration"
    public static let captureCursor = "pixcapCaptureCursor"
    public static let retinaScaling = "pixcapRetinaScaling"

    // Output & export
    public static let defaultFormat = "pixcapDefaultFormat"
    public static let jpgQuality = "pixcapJpgQuality"
    public static let saveDirectory = "pixcapSaveDirectory"
    public static let fileNamingPattern = "pixcapFileNamingPattern"
    public static let autoCopyClipboard = "pixcapAutoCopyClipboard"
    public static let add2xSuffix = "pixcapAdd2xSuffix"
    public static let captureCounter = "pixcapCaptureCounter"

    // After-capture workflow
    public static let showQuickAccess = "pixcapShowQuickAccess"
    public static let quickAccessDismiss = "pixcapQuickAccessDismiss"
    public static let afterCaptureAction = "pixcapAfterCaptureAction"
    public static let pinToScreenDefault = "pixcapPinToScreenDefault"

    // Canvas & beautification
    public static let defaultBackgroundPreset = "pixcapDefaultBackgroundPreset"
    public static let defaultPadding = "pixcapDefaultPadding"
    public static let defaultCornerRadius = "pixcapDefaultCornerRadius"
    public static let defaultShadowBlur = "pixcapDefaultShadowBlur"
    public static let defaultWindowFrame = "pixcapDefaultWindowFrame"
    public static let showLineNumbers = "pixcapShowLineNumbers"
    public static let fontLigatures = "pixcapFontLigatures"
    public static let defaultCodeFont = "pixcapDefaultCodeFont"
    public static let defaultCodeFontSize = "pixcapDefaultCodeFontSize"

    // Annotation defaults
    public static let defaultStrokeColorHex = "pixcapDefaultStrokeColorHex"
    public static let defaultStrokeWidth = "pixcapDefaultStrokeWidth"
    public static let defaultFillColorHex = "pixcapDefaultFillColorHex"
    public static let defaultTextFontSize = "pixcapDefaultTextFontSize"
    public static let arrowStyle = "pixcapArrowStyle"
    public static let blurIntensity = "pixcapBlurIntensity"
    public static let counterStartNumber = "pixcapCounterStartNumber"

    // Recording
    public static let recordingDefaultFormat = "pixcapRecordingDefaultFormat"
    public static let videoFPS = "pixcapVideoFPS"
    public static let audioSource = "pixcapAudioSource"
    public static let showCursorInRecording = "pixcapShowCursorInRecording"
    public static let highlightMouseClicks = "pixcapHighlightMouseClicks"
    public static let showKeystrokes = "pixcapShowKeystrokes"
    public static let gifFPS = "pixcapGifFPS"
    public static let showCountdown = "pixcapShowCountdown"

    // IDE & CLI
    public static let enableIpcServer = "pixcapEnableIpcServer"
    public static let autoStartIpc = "pixcapAutoStartIpc"

    // OCR
    public static let ocrPreserveLineBreaks = "pixcapOcrPreserveLineBreaks"
    public static let ocrDetectBarcodes = "pixcapOcrDetectBarcodes"
    public static let ocrStoreInHistory = "pixcapOcrStoreInHistory"

    // On-device code explanation (Ollama)
    public static let ollamaEndpoint = "pixcapOllamaEndpoint"
    public static let ollamaModel = "pixcapOllamaModel"

    // Non-destructive editing
    public static let saveEditDocuments = "pixcapSaveEditDocuments"

    // Privacy
    public static let autoRedactApiKeys = "pixcapAutoRedactApiKeys"
    public static let autoRedactEmails = "pixcapAutoRedactEmails"
    public static let autoRedactIps = "pixcapAutoRedactIps"
    public static let autoRedactCreditCards = "pixcapAutoRedactCreditCards"
    public static let redactionStyle = "pixcapRedactionStyle"
    public static let redactionColorHex = "pixcapRedactionColorHex"
}

/// Typed access to the settings the capture pipeline needs at runtime.
public enum Settings {
    private static var defaults: UserDefaults { .standard }

    /// Registers factory defaults so a fresh install behaves like the Preferences UI advertises.
    public static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.playCaptureSound: true,
            SettingsKey.showNotifications: true,
            SettingsKey.checkForUpdates: true,
            SettingsKey.defaultCaptureMode: "Area",
            SettingsKey.showMagnifier: true,
            SettingsKey.captureWindowShadow: true,
            SettingsKey.freezeScreen: true,
            SettingsKey.selfTimerDuration: "2s",
            SettingsKey.retinaScaling: "Native 2x",
            SettingsKey.defaultFormat: "PNG",
            SettingsKey.jpgQuality: 90.0,
            SettingsKey.saveDirectory: defaultSaveDirectory.path,
            SettingsKey.fileNamingPattern: PixCapBridge.shared.defaultNamingPattern,
            SettingsKey.autoCopyClipboard: true,
            SettingsKey.showQuickAccess: true,
            SettingsKey.quickAccessDismiss: "5s",
            SettingsKey.afterCaptureAction: "Open Editor",
            SettingsKey.defaultBackgroundPreset: "azure-mesh",
            SettingsKey.defaultPadding: 32.0,
            SettingsKey.defaultCornerRadius: 16.0,
            SettingsKey.defaultShadowBlur: 24.0,
            SettingsKey.defaultWindowFrame: "macOS",
            SettingsKey.defaultStrokeColorHex: "#FF3366",
            SettingsKey.defaultStrokeWidth: 3.0,
            SettingsKey.defaultFillColorHex: "#FF336640",
            SettingsKey.defaultTextFontSize: 24,
            SettingsKey.arrowStyle: "Curved",
            SettingsKey.blurIntensity: 20.0,
            SettingsKey.counterStartNumber: 1,
            SettingsKey.recordingDefaultFormat: "MP4",
            SettingsKey.videoFPS: "60",
            SettingsKey.audioSource: "System",
            SettingsKey.enableIpcServer: true,
            SettingsKey.autoStartIpc: true,
            SettingsKey.autoRedactApiKeys: true,
            SettingsKey.autoRedactEmails: true,
            SettingsKey.autoRedactCreditCards: true,
            SettingsKey.redactionStyle: "Blur",
            SettingsKey.redactionColorHex: "#000000",
            SettingsKey.ocrPreserveLineBreaks: true,
            SettingsKey.ocrDetectBarcodes: true,
            SettingsKey.ocrStoreInHistory: true,
            SettingsKey.saveEditDocuments: true,
            SettingsKey.ollamaEndpoint: "http://localhost:11434",
            SettingsKey.ollamaModel: "llama3.2",
            SettingsKey.gifFPS: "15",
            SettingsKey.showCursorInRecording: true,
            SettingsKey.showCountdown: true
        ])
    }

    public static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    public static func double(_ key: String) -> Double { defaults.double(forKey: key) }
    public static func int(_ key: String) -> Int { defaults.integer(forKey: key) }
    public static func string(_ key: String, default fallback: String = "") -> String {
        defaults.string(forKey: key) ?? fallback
    }

    public static var defaultSaveDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("PixCap", isDirectory: true)
    }

    /// Save directory from preferences, expanding `~` and falling back to the default.
    public static var saveDirectory: URL {
        let raw = string(SettingsKey.saveDirectory)
        guard !raw.isEmpty else { return defaultSaveDirectory }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var namingPattern: String {
        let pattern = string(SettingsKey.fileNamingPattern)
        return pattern.isEmpty ? PixCapBridge.shared.defaultNamingPattern : pattern
    }

    /// Self-timer delay in seconds, parsed from the `"2s"`-style preference.
    public static var selfTimerSeconds: Double {
        Double(string(SettingsKey.selfTimerDuration, default: "2s").dropLast()) ?? 2.0
    }

    /// Quick Access auto-dismiss delay; `nil` means "Never".
    public static var quickAccessDismissSeconds: Double? {
        let raw = string(SettingsKey.quickAccessDismiss, default: "5s")
        if raw == "Never" { return nil }
        return Double(raw.dropLast()) ?? 5.0
    }

    /// Pixels per point for captures and exports, honouring the Retina scaling preference.
    public static func renderScale(for screen: NSScreen? = nil) -> CGFloat {
        guard string(SettingsKey.retinaScaling, default: "Native 2x") != "Downscale 1x" else { return 1.0 }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// Monotonically increasing capture counter used by `{counter}` in naming patterns.
    public static func nextCaptureCounter() -> Int {
        let next = int(SettingsKey.captureCounter) + 1
        defaults.set(next, forKey: SettingsKey.captureCounter)
        return next
    }

    public enum ExportFormat: String {
        case png = "PNG"
        case jpg = "JPG"
        case webp = "WebP"

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpg: return "jpg"
            // AppKit has no WebP encoder; PNG is the lossless stand-in until the
            // Rust `image` crate encoder is wired through FFI.
            case .webp: return "png"
            }
        }

        public var bitmapType: NSBitmapImageRep.FileType {
            switch self {
            case .jpg: return .jpeg
            default: return .png
            }
        }
    }

    public static var exportFormat: ExportFormat {
        ExportFormat(rawValue: string(SettingsKey.defaultFormat, default: "PNG")) ?? .png
    }

    public enum AfterCaptureAction: String {
        case copyToClipboard = "Copy to Clipboard"
        case saveToDisk = "Save to Disk"
        case openEditor = "Open Editor"
    }

    public static var afterCaptureAction: AfterCaptureAction {
        AfterCaptureAction(rawValue: string(SettingsKey.afterCaptureAction, default: "Open Editor")) ?? .openEditor
    }
}

// MARK: - Colour helpers

public extension NSColor {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`. Returns nil for malformed input.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8, let intValue = UInt64(value, radix: 16) else {
            return nil
        }

        let hasAlpha = value.count == 8
        let r = CGFloat((intValue >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0
        let g = CGFloat((intValue >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0
        let b = CGFloat((intValue >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0
        let a = hasAlpha ? CGFloat(intValue & 0xFF) / 255.0 : 1.0

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` (or `#RRGGBBAA` when partly transparent).
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
