import SwiftUI

/// The complete settings catalogue.
///
/// Rows carrying `unavailable:` are shown disabled with the reason, so the pane
/// never silently ignores a control the user changes.
@available(macOS 14.0, *)
public enum SettingsCatalog {

    private static let notBuilt = "Not implemented yet"
    private static let fixedTypography = "Code rendering uses fixed typography for now"
    private static let autoRedactionNote = "Automatic redaction is not built — use the Redaction tool in the editor"

    public static let categories: [SettingCategory] = [

        SettingCategory(id: "general", title: "General", symbol: "gearshape.fill", tint: .gray, groups: [
            SettingGroup("Startup", items: [
                SettingItem("Launch at login",
                            subtitle: "Start PixCap automatically when you log in.",
                            control: .toggle(key: SettingsKey.launchAtLogin),
                            keywords: ["startup", "boot", "login item"]),
                SettingItem("Menu bar icon",
                            subtitle: "Hotkeys keep working while the icon is hidden. Relaunch PixCap to bring it back.",
                            control: .menu(key: SettingsKey.menuBarIconStyle, options: ["Icon Only", "Icon + Text", "Hidden"]),
                            keywords: ["status bar", "tray", "hide"])
            ]),
            SettingGroup("Appearance", items: [
                SettingItem("Colour scheme",
                            subtitle: "Applies to PixCap's own windows.",
                            control: .segmented(key: SettingsKey.colorScheme, options: ["System", "Dark", "Light"]),
                            keywords: ["dark mode", "light mode", "theme", "appearance"])
            ]),
            SettingGroup("Feedback", items: [
                SettingItem("Play a sound on capture",
                            control: .toggle(key: SettingsKey.playCaptureSound),
                            keywords: ["shutter", "audio"]),
                SettingItem("Show a notification after capture",
                            control: .toggle(key: SettingsKey.showNotifications),
                            keywords: ["banner", "alert"])
            ]),
            SettingGroup("Maintenance", footer: "Resetting also restores every keyboard shortcut.", items: [
                SettingItem("Check for updates automatically",
                            control: .toggle(key: SettingsKey.checkForUpdates),
                            keywords: ["upgrade", "version"],
                            unavailable: "No updater is built yet"),
                SettingItem("Reset all settings",
                            subtitle: "Restore every PixCap preference to its default.",
                            control: .custom(id: "resetAll"),
                            keywords: ["defaults", "factory", "clear"])
            ])
        ]),

        SettingCategory(id: "capture", title: "Capture", symbol: "camera.fill", tint: .blue, groups: [
            SettingGroup("Timing", items: [
                SettingItem("Self-timer delay",
                            subtitle: "Countdown shown before a timed capture starts.",
                            control: .menu(key: SettingsKey.selfTimerDuration, options: ["2s", "5s", "10s"]),
                            keywords: ["countdown", "delay"]),
                SettingItem("Default capture mode",
                            control: .menu(key: SettingsKey.defaultCaptureMode, options: ["Area", "Window", "Fullscreen"]),
                            keywords: ["region", "screen"],
                            unavailable: "Each capture mode has its own menu item and hotkey")
            ]),
            SettingGroup("Contents", items: [
                SettingItem("Include the pointer",
                            subtitle: "Draw the mouse cursor into the captured image.",
                            control: .toggle(key: SettingsKey.captureCursor),
                            keywords: ["mouse", "cursor", "pointer"]),
                SettingItem("Include window shadow",
                            subtitle: "Keeps the soft drop shadow around a captured window.",
                            control: .toggle(key: SettingsKey.captureWindowShadow),
                            keywords: ["shadow", "window"]),
                SettingItem("Retina scaling",
                            subtitle: "Native captures at the display's full pixel density.",
                            control: .menu(key: SettingsKey.retinaScaling, options: ["Native 2x", "Downscale 1x"]),
                            keywords: ["hidpi", "resolution", "scale", "2x"])
            ]),
            SettingGroup("Selection aids", items: [
                SettingItem("Remember the last region",
                            control: .toggle(key: SettingsKey.rememberRegion),
                            keywords: ["previous area"], unavailable: notBuilt),
                SettingItem("Show magnifier loupe",
                            control: .toggle(key: SettingsKey.showMagnifier),
                            keywords: ["zoom", "pixel"], unavailable: notBuilt),
                SettingItem("Freeze the screen while selecting",
                            control: .toggle(key: SettingsKey.freezeScreen),
                            keywords: ["pause"], unavailable: notBuilt),
                SettingItem("Hide desktop icons before capture",
                            control: .toggle(key: SettingsKey.hideDesktopIcons),
                            keywords: ["desktop", "clean"], unavailable: notBuilt)
            ])
        ]),

        SettingCategory(id: "output", title: "Output", symbol: "square.and.arrow.down.fill", tint: .indigo, groups: [
            SettingGroup("Format", items: [
                SettingItem("File format",
                            control: .segmented(key: SettingsKey.defaultFormat, options: ["PNG", "JPG", "WebP"]),
                            keywords: ["png", "jpeg", "webp", "export"]),
                SettingItem("JPEG quality",
                            subtitle: "Only applies when the format is JPG.",
                            control: .slider(key: SettingsKey.jpgQuality, range: 1...100, unit: "%"),
                            keywords: ["compression"])
            ]),
            SettingGroup("Location", items: [
                SettingItem("Save to",
                            control: .custom(id: "saveDirectory"),
                            keywords: ["folder", "directory", "path"]),
                SettingItem("File name pattern",
                            control: .textField(key: SettingsKey.fileNamingPattern, placeholder: "PixCap_{date}_{time}_{counter}"),
                            keywords: ["naming", "template", "filename"]),
                SettingItem("Name preview",
                            control: .custom(id: "namingPreview"),
                            keywords: ["example"])
            ]),
            SettingGroup("Clipboard", items: [
                SettingItem("Copy every capture to the clipboard",
                            control: .toggle(key: SettingsKey.autoCopyClipboard),
                            keywords: ["paste", "copy"]),
                SettingItem("Add @2x to Retina file names",
                            control: .toggle(key: SettingsKey.add2xSuffix),
                            keywords: ["suffix", "retina"])
            ])
        ]),

        SettingCategory(id: "workflow", title: "After Capture", symbol: "bolt.fill", tint: .orange, groups: [
            SettingGroup("What happens next", items: [
                SettingItem("Then",
                            subtitle: "Every capture is saved to disk first, so history always has a copy.",
                            control: .menu(key: SettingsKey.afterCaptureAction, options: ["Open Editor", "Copy to Clipboard", "Save to Disk"]),
                            keywords: ["action", "editor"]),
                SettingItem("Pin the capture to the screen",
                            control: .toggle(key: SettingsKey.pinToScreenDefault),
                            keywords: ["float", "always on top"])
            ]),
            SettingGroup("Quick Access", footer: "The floating thumbnail lets you edit, copy, or drag a capture straight into another app.", items: [
                SettingItem("Show the floating thumbnail",
                            control: .toggle(key: SettingsKey.showQuickAccess),
                            keywords: ["overlay", "thumbnail"]),
                SettingItem("Dismiss after",
                            control: .menu(key: SettingsKey.quickAccessDismiss, options: ["3s", "5s", "10s", "Never"]),
                            keywords: ["timeout", "auto hide"])
            ])
        ]),

        SettingCategory(id: "canvas", title: "Canvas", symbol: "paintbrush.fill", tint: .pink, groups: [
            SettingGroup("Defaults for new captures", items: [
                SettingItem("Background",
                            control: .custom(id: "backgroundPreset"),
                            keywords: ["gradient", "preset", "wallpaper"]),
                SettingItem("Window frame",
                            control: .menu(key: SettingsKey.defaultWindowFrame, options: ["macOS", "Windows", "Minimal", "None"]),
                            keywords: ["chrome", "traffic lights", "titlebar"]),
                SettingItem("Padding",
                            control: .slider(key: SettingsKey.defaultPadding, range: 0...160, unit: "pt"),
                            keywords: ["margin", "space"]),
                SettingItem("Corner radius",
                            control: .slider(key: SettingsKey.defaultCornerRadius, range: 0...48, unit: "pt"),
                            keywords: ["rounded"]),
                SettingItem("Shadow blur",
                            control: .slider(key: SettingsKey.defaultShadowBlur, range: 0...80, unit: "pt"),
                            keywords: ["drop shadow", "depth"])
            ]),
            SettingGroup("Code snippets", items: [
                SettingItem("Show line numbers",
                            control: .toggle(key: SettingsKey.showLineNumbers),
                            keywords: ["gutter"], unavailable: fixedTypography),
                SettingItem("Font ligatures",
                            control: .toggle(key: SettingsKey.fontLigatures),
                            keywords: ["fira", "jetbrains mono"], unavailable: fixedTypography),
                SettingItem("Code font",
                            control: .menu(key: SettingsKey.defaultCodeFont, options: ["SF Mono", "Fira Code", "JetBrains Mono", "Menlo"]),
                            keywords: ["typeface", "monospace"], unavailable: fixedTypography),
                SettingItem("Code font size",
                            control: .stepper(key: SettingsKey.defaultCodeFontSize, range: 10...24),
                            keywords: ["size"], unavailable: fixedTypography)
            ])
        ]),

        SettingCategory(id: "annotate", title: "Annotation", symbol: "pencil.tip.crop.circle.fill", tint: .red, groups: [
            SettingGroup("Drawing defaults", items: [
                SettingItem("Stroke colour",
                            control: .color(key: SettingsKey.defaultStrokeColorHex),
                            keywords: ["colour", "pen"]),
                SettingItem("Stroke width",
                            control: .slider(key: SettingsKey.defaultStrokeWidth, range: 1...12, unit: "pt"),
                            keywords: ["thickness", "weight"]),
                SettingItem("Arrow style",
                            control: .segmented(key: SettingsKey.arrowStyle, options: ["Straight", "Curved"]),
                            keywords: ["arrow", "bow"]),
                SettingItem("Fill colour",
                            control: .color(key: SettingsKey.defaultFillColorHex),
                            keywords: ["shape fill"],
                            unavailable: "Shapes fill with a translucent stroke colour")
            ]),
            SettingGroup("Tools", items: [
                SettingItem("Text size",
                            control: .stepper(key: SettingsKey.defaultTextFontSize, range: 12...48),
                            keywords: ["font", "label"]),
                SettingItem("Blur intensity",
                            control: .slider(key: SettingsKey.blurIntensity, range: 5...60),
                            keywords: ["pixelate", "obscure"]),
                SettingItem("Counter starts at",
                            control: .stepper(key: SettingsKey.counterStartNumber, range: 1...99),
                            keywords: ["number", "step", "bubble"])
            ])
        ]),

        SettingCategory(id: "recording", title: "Recording", symbol: "record.circle.fill", tint: .purple, groups: [
            SettingGroup("Format", items: [
                SettingItem("Record as",
                            control: .segmented(key: SettingsKey.recordingDefaultFormat, options: ["MP4", "GIF"]),
                            keywords: ["video", "gif", "movie"]),
                SettingItem("Video frame rate",
                            control: .segmented(key: SettingsKey.videoFPS, options: ["30", "60"]),
                            keywords: ["fps", "smooth"]),
                SettingItem("GIF frame rate",
                            control: .menu(key: SettingsKey.gifFPS, options: ["10", "15", "20", "30"]),
                            keywords: ["fps", "gif"])
            ]),
            SettingGroup("Audio", footer: "Only system audio is captured. Microphone input is not implemented.", items: [
                SettingItem("Audio source",
                            control: .menu(key: SettingsKey.audioSource, options: ["None", "System", "Microphone", "Both"]),
                            keywords: ["sound", "mic", "system audio"])
            ]),
            SettingGroup("On screen", items: [
                SettingItem("Show the pointer",
                            control: .toggle(key: SettingsKey.showCursorInRecording),
                            keywords: ["cursor", "mouse"]),
                SettingItem("Count down before recording",
                            control: .toggle(key: SettingsKey.showCountdown),
                            keywords: ["321", "delay"]),
                SettingItem("Highlight mouse clicks",
                            control: .toggle(key: SettingsKey.highlightMouseClicks),
                            keywords: ["click"], unavailable: notBuilt),
                SettingItem("Show keystrokes",
                            control: .toggle(key: SettingsKey.showKeystrokes),
                            keywords: ["keys", "overlay"], unavailable: notBuilt)
            ])
        ]),

        SettingCategory(id: "hotkeys", title: "Shortcuts", symbol: "keyboard.fill", tint: .teal, groups: [
            SettingGroup(items: [SettingItem("Global shortcuts", control: .custom(id: "hotkeys"),
                                             keywords: ["hotkey", "keyboard", "binding", "shortcut"])])
        ]),

        SettingCategory(id: "ocr", title: "Text Recognition", symbol: "text.viewfinder", tint: .cyan, groups: [
            SettingGroup("Extraction", footer: "Recognition uses Apple's Vision framework. No image or text leaves this Mac.", items: [
                SettingItem("Preserve line breaks",
                            subtitle: "Keeps the original layout instead of reflowing into a paragraph.",
                            control: .toggle(key: SettingsKey.ocrPreserveLineBreaks),
                            keywords: ["ocr", "layout", "newline"]),
                SettingItem("Recognise QR codes and barcodes",
                            control: .toggle(key: SettingsKey.ocrDetectBarcodes),
                            keywords: ["qr", "barcode", "scan"])
            ]),
            SettingGroup("Searchable history", items: [
                SettingItem("Index captured text",
                            subtitle: "Reads each capture on-device so History search can find screenshots by their contents.",
                            control: .toggle(key: SettingsKey.ocrStoreInHistory),
                            keywords: ["search", "archive", "index"])
            ])
        ]),

        SettingCategory(id: "ide", title: "Integrations", symbol: "chevron.left.forwardslash.chevron.right", tint: .green, groups: [
            SettingGroup(items: [SettingItem("Editors and CLI", control: .custom(id: "ide"),
                                             keywords: ["vs code", "jetbrains", "rider", "rustrover", "cli", "plugin", "extension"])]),
            SettingGroup("IPC server", footer: "The IPC crate exists in the workspace but the app does not start it yet.", items: [
                SettingItem("Enable the IPC server",
                            control: .toggle(key: SettingsKey.enableIpcServer),
                            keywords: ["socket", "ipc"], unavailable: notBuilt),
                SettingItem("Start it on launch",
                            control: .toggle(key: SettingsKey.autoStartIpc),
                            keywords: ["socket", "ipc"], unavailable: notBuilt)
            ])
        ]),

        SettingCategory(id: "privacy", title: "Privacy", symbol: "hand.raised.fill", tint: .brown, groups: [
            SettingGroup("Redaction", footer: "Everything PixCap does runs on this Mac. Nothing is uploaded.", items: [
                SettingItem("Redaction colour",
                            subtitle: "Used by the Redaction tool in the editor.",
                            control: .color(key: SettingsKey.redactionColorHex),
                            keywords: ["block", "censor", "colour"]),
                SettingItem("Redaction style",
                            control: .menu(key: SettingsKey.redactionStyle, options: ["Blur", "Solid Block", "Pixelate"]),
                            keywords: ["blur", "pixelate"],
                            unavailable: "Applies to automatic redaction, which is not built"),
                SettingItem("Auto-redact API keys",
                            control: .toggle(key: SettingsKey.autoRedactApiKeys),
                            keywords: ["secret", "token"], unavailable: autoRedactionNote),
                SettingItem("Auto-redact email addresses",
                            control: .toggle(key: SettingsKey.autoRedactEmails),
                            keywords: ["email"], unavailable: autoRedactionNote),
                SettingItem("Auto-redact IP addresses",
                            control: .toggle(key: SettingsKey.autoRedactIps),
                            keywords: ["ip"], unavailable: autoRedactionNote),
                SettingItem("Auto-redact card numbers",
                            control: .toggle(key: SettingsKey.autoRedactCreditCards),
                            keywords: ["credit card", "pan"], unavailable: autoRedactionNote)
            ])
        ]),

        SettingCategory(id: "about", title: "About", symbol: "info.circle.fill", tint: .secondary, groups: [
            SettingGroup(items: [SettingItem("About PixCap", control: .custom(id: "about"),
                                             keywords: ["version", "build", "licence"])])
        ])
    ]
}
