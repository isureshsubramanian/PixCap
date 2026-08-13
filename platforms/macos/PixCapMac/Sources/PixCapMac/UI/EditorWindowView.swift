import SwiftUI
import Cocoa
import WebKit
import UniformTypeIdentifiers

@available(macOS 14.0, *)
public struct EditorWindowView: View {
    let inputImage: NSImage?
    let captureMode: String
    /// Set when the image came from disk, enabling sidecar restore.
    let sourceURL: URL?

    @StateObject private var store = AnnotationStore()

    @State private var config = BeautifyConfig.fromPreferences()
    @State private var shadowOpacity: Double = 35
    @State private var frameTitle: String = ""

    @State private var tool: AnnotationTool = .select
    @State private var strokeColor: Color = Color(NSColor(hex: Settings.string(SettingsKey.defaultStrokeColorHex, default: "#FF3366")) ?? .systemRed)
    @State private var strokeWidth: Double = Settings.double(SettingsKey.defaultStrokeWidth)
    @State private var filled: Bool = false
    @State private var blurStyle: BlurStyle = .gaussian
    @State private var blurIntensity: Double = Settings.double(SettingsKey.blurIntensity)
    @State private var textSize: Double = Double(Settings.int(SettingsKey.defaultTextFontSize))
    @State private var curvedArrow: Bool = Settings.string(SettingsKey.arrowStyle, default: "Curved") == "Curved"
    @State private var arrowHead: ArrowHead = .filled
    @State private var dashed: Bool = false

    @State private var statusMessage: String = "Ready"
    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var mode: EditorMode
    @State private var codeText: String = "// PixCap renders code through the shared Rust core\nfn main() {\n    println!(\"Hello, PixCap\");\n}"
    @State private var codeLanguage: String = "rs"
    @State private var codeSVG: String = ""

    private let presets = PixCapBridge.shared.backgroundPresets
    /// Every language the Rust engine supports, not a hardcoded subset.
    private let languages = PixCapBridge.shared.syntaxLanguages
    private let syntaxThemes = PixCapBridge.shared.syntaxThemes

    @State private var languageQuery: String = ""
    @State private var syntaxTheme: String = "base16-ocean.dark"

    enum EditorMode: String, CaseIterable {
        case image = "Image"
        case code = "Code"
    }

    public init(inputImage: NSImage?, captureMode: String = "area", sourceURL: URL? = nil) {
        self.inputImage = inputImage
        self.captureMode = captureMode
        self.sourceURL = sourceURL
        self._mode = State(initialValue: inputImage == nil ? .code : .image)
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if mode == .image {
                AnnotationOptionsBar(
                    tool: $tool,
                    color: $strokeColor,
                    strokeWidth: $strokeWidth,
                    filled: $filled,
                    blurStyle: $blurStyle,
                    blurIntensity: $blurIntensity,
                    textSize: $textSize,
                    curvedArrow: $curvedArrow,
                    arrowHead: $arrowHead,
                    dashed: $dashed
                )
                .background(Color(NSColor.windowBackgroundColor))
                Divider()
            }

            HSplitView {
                canvasArea
                sidebar
            }

            Divider()
            statusBar
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            syncShadowOpacity()
            restoreDocumentIfAvailable()
        }
        .onChange(of: shadowOpacity) { _, value in config.shadowOpacity = CGFloat(value) / 100.0 }
        .onChange(of: frameTitle) { _, value in config.frameTitle = value.isEmpty ? nil : value }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(EditorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .disabled(inputImage == nil)

            Spacer()

            Button(action: saveToFile) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button(action: copyToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button(action: shareImage) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Menu {
                Button("Extract Text (OCR)", action: extractText)
                Button("Pin to Screen", action: pinToScreen)
                Button("Save Editable Copy", action: saveDocument)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)
            .disabled(inputImage == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Canvas

    @ViewBuilder private var canvasArea: some View {
        VStack(spacing: 12) {
            if mode == .image, let image = inputImage {
                BeautifiedCanvasView(
                    image: image,
                    store: store,
                    config: config,
                    tool: $tool,
                    strokeColor: $strokeColor,
                    strokeWidth: $strokeWidth,
                    filled: $filled,
                    blurStyle: $blurStyle,
                    blurIntensity: $blurIntensity,
                    textSize: $textSize,
                    curvedArrow: $curvedArrow,
                    arrowHead: $arrowHead,
                    dashed: $dashed,
                    onCrop: { rect in
                        config.crop = rect
                        tool = .select
                        statusMessage = "Cropped to \(Int(rect.width)) × \(Int(rect.height)) — reset from the sidebar"
                    }
                )
                .padding(20)

                AnnotationToolsView(selectedTool: $tool, store: store)
                    .padding(.bottom, 14)
            } else if mode == .code {
                codeEditor
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No image captured")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var codeEditor: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    // Searchable because the engine ships well over a hundred
                    // syntaxes — a plain menu would be unusable.
                    Picker("Language", selection: $codeLanguage) {
                        ForEach(filteredLanguages) { language in
                            Text(language.name).tag(language.token)
                        }
                    }
                    .frame(width: 210)

                    TextField("Filter…", text: $languageQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    Picker("Theme", selection: $syntaxTheme) {
                        ForEach(syntaxThemes, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 220)

                    Spacer()
                    Button(isExplaining ? "Explaining…" : "Explain") { explainCode() }
                        .disabled(isExplaining || codeText.isEmpty)
                        .help("Explain this snippet using a local Ollama model")
                    Button("Render", action: renderCode)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Text("\(languages.count) languages · \(syntaxThemes.count) themes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                TextEditor(text: $codeText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)

                if let explanation {
                    Divider()
                    ScrollView {
                        Text(explanation)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                }
            }
            .frame(minHeight: 160)

            SVGPreview(svg: codeSVG)
                .frame(minHeight: 200)
        }
        .onAppear(perform: renderCode)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Background").font(.subheadline).bold().lineLimit(1)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                        ForEach(presets) { preset in
                            PresetSwatch(
                                preset: preset,
                                isSelected: config.background == .preset(id: preset.id)
                            ) {
                                config.background = .preset(id: preset.id)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Wallpaper") { config.background = .desktopWallpaper }
                            .lineLimit(1)
                        Button("Image…", action: chooseBackgroundImage)
                            .lineLimit(1)
                    }
                    .font(.caption)

                    if case .preset = config.background {} else {
                        sliderRow(title: "Background blur", value: Binding(
                            get: { Double(config.backgroundBlur) },
                            set: { config.backgroundBlur = CGFloat($0) }
                        ), range: 0...40)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Texture").font(.subheadline).bold().lineLimit(1)

                    Picker("", selection: $config.texture) {
                        ForEach(CanvasTexture.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .lineLimit(1)

                    sliderRow(title: "Grain", value: Binding(
                        get: { Double(config.noiseIntensity) },
                        set: { config.noiseIntensity = CGFloat($0) }
                    ), range: 0...1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Perspective").font(.subheadline).bold().lineLimit(1)

                    sliderRow(title: "Tilt X", value: Binding(
                        get: { Double(config.tiltX) },
                        set: { config.tiltX = CGFloat($0) }
                    ), range: -45...45)

                    sliderRow(title: "Tilt Y", value: Binding(
                        get: { Double(config.tiltY) },
                        set: { config.tiltY = CGFloat($0) }
                    ), range: -45...45)

                    if config.tiltX != 0 || config.tiltY != 0 {
                        Button("Reset tilt") {
                            config.tiltX = 0
                            config.tiltY = 0
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                }

                Divider()

                sliderRow(title: "Padding", value: Binding(
                    get: { Double(config.padding) },
                    set: { config.padding = CGFloat($0) }
                ), range: 0...160)

                sliderRow(title: "Corner radius", value: Binding(
                    get: { Double(config.cornerRadius) },
                    set: { config.cornerRadius = CGFloat($0) }
                ), range: 0...48)

                sliderRow(title: "Shadow blur", value: Binding(
                    get: { Double(config.shadowBlur) },
                    set: { config.shadowBlur = CGFloat($0) }
                ), range: 0...80)

                sliderRow(title: "Shadow opacity", value: $shadowOpacity, range: 0...100)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Frame", selection: $config.frameStyle) {
                        ForEach(WindowFrameStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .lineLimit(1)

                    Picker("Ratio", selection: $config.aspectRatio) {
                        ForEach(AspectRatioPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .lineLimit(1)

                    if config.frameStyle != .none {
                        TextField("Window title", text: $frameTitle)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                    }
                }

                if config.crop != nil {
                    Divider()
                    HStack {
                        Label("Cropped", systemImage: "crop")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button("Reset") { config.crop = nil }
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Divider()

                Button("Reset to defaults") {
                    let crop = config.crop
                    config = BeautifyConfig.fromPreferences()
                    config.crop = crop
                    syncShadowOpacity()
                }
                .lineLimit(1)
            }
            .padding(14)
        }
        .frame(width: 270)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).bold().lineLimit(1)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.caption).foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage).lineLimit(1)
            Spacer()
            if mode == .image, let image = inputImage {
                let layout = BeautifierRenderer.layout(imageSize: image.size, config: config)
                Text("Canvas \(Int(layout.canvasSize.width)) × \(Int(layout.canvasSize.height)) · Source \(Int(image.size.width)) × \(Int(image.size.height))")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Actions

    private func syncShadowOpacity() {
        shadowOpacity = Double(config.shadowOpacity) * 100
    }

    /// The beautified composite, exactly as it will be exported.
    private func composedImage() -> NSImage? {
        guard let image = inputImage else { return nil }
        return BeautifierRenderer.render(image: image, annotations: store.items, config: config, scale: Settings.renderScale())
    }

    private func copyToClipboard() {
        if mode == .code {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeSVG, forType: .string)
            statusMessage = "Copied SVG markup"
            return
        }

        guard let composite = composedImage() else {
            statusMessage = "Nothing to copy"
            return
        }
        ImageExporter.copyToClipboard(composite)
        statusMessage = "Copied beautified image to clipboard"
    }

    private func saveToFile() {
        let panel = NSSavePanel()

        if mode == .code {
            panel.allowedContentTypes = [UTType.svg]
            panel.nameFieldStringValue = "PixCap-Snippet.svg"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try codeSVG.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "Saved \(url.lastPathComponent)"
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
            return
        }

        guard let composite = composedImage() else {
            statusMessage = "Nothing to save"
            return
        }

        let format = Settings.exportFormat
        panel.allowedContentTypes = [format.bitmapType == .jpeg ? UTType.jpeg : UTType.png]
        panel.nameFieldStringValue = PixCapBridge.shared.resolveFilename(
            pattern: Settings.namingPattern,
            mode: captureMode,
            appName: nil,
            windowTitle: frameTitle.isEmpty ? nil : frameTitle,
            width: Int(composite.size.width),
            height: Int(composite.size.height),
            counter: Settings.int(SettingsKey.captureCounter)
        ) + "." + format.fileExtension

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = ImageExporter.data(from: composite, format: format) else {
            statusMessage = "Could not encode image"
            return
        }

        do {
            try data.write(to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func shareImage() {
        guard let composite = composedImage(),
              let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            statusMessage = "Nothing to share"
            return
        }

        let picker = NSSharingServicePicker(items: [composite])
        picker.show(
            relativeTo: NSRect(x: contentView.bounds.maxX - 120, y: contentView.bounds.maxY - 40, width: 1, height: 1),
            of: contentView,
            preferredEdge: .minY
        )
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            config.background = .customImage(url: url)
        }
    }

    /// Languages matching the filter box, always including the current choice
    /// so the picker never loses its selection while typing.
    private var filteredLanguages: [SyntaxLanguage] {
        let query = languageQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return languages }

        return languages.filter { language in
            language.token == codeLanguage
                || language.name.lowercased().contains(query)
                || language.extensions.contains { $0.lowercased().contains(query) }
        }
    }

    /// Explains the snippet with a locally-running model.
    private func explainCode() {
        isExplaining = true
        explanation = nil

        let name = languages.first { $0.token == codeLanguage }?.name ?? codeLanguage
        let snippet = codeText

        Task {
            do {
                let text = try await CodeExplainer.explain(code: snippet, language: name)
                await MainActor.run {
                    explanation = text
                    statusMessage = "Explained with \(CodeExplainer.model)"
                    isExplaining = false
                }
            } catch {
                await MainActor.run {
                    explanation = nil
                    statusMessage = error.localizedDescription
                    isExplaining = false
                }
            }
        }
    }

    private func renderCode() {
        codeSVG = PixCapBridge.shared.renderSnippet(
            code: codeText,
            language: codeLanguage,
            theme: syntaxTheme
        ) ?? ""

        let name = languages.first { $0.token == codeLanguage }?.name ?? codeLanguage
        statusMessage = codeSVG.isEmpty
            ? "The renderer returned no output"
            : "Rendered \(name) with \(syntaxTheme)"
    }

    // MARK: - Phase 2 actions

    /// Rectangles, in image space, of every annotation that hides what is under it.
    private func concealedRegions() -> [CGRect] {
        store.items
            .filter { $0.tool.concealsContent }
            .map { CGRect(x: min($0.start.x, $0.end.x),
                          y: min($0.start.y, $0.end.y),
                          width: abs($0.end.x - $0.start.x),
                          height: abs($0.end.y - $0.start.y)) }
            .filter { !$0.isEmpty }
    }

    /// Copies the text in the capture — the text still *visible* in it.
    ///
    /// Recognition runs on the source rather than the composite, because the
    /// composite is scaled and sits on a background, both of which cost
    /// accuracy. That means Vision also reads whatever is under a blur or a
    /// redaction, so those lines are dropped before anything reaches the
    /// clipboard. Extracting text someone deliberately hid would quietly
    /// undo the redaction.
    private func extractText() {
        guard let image = inputImage else { return }

        do {
            let hidden = concealedRegions()
            let recognition = try OCRService.recognize(
                in: image,
                includeBarcodes: Settings.bool(SettingsKey.ocrDetectBarcodes)
            ).excludingText(coveredBy: hidden, imageSize: image.size)

            guard !recognition.isEmpty else {
                statusMessage = hidden.isEmpty ? "No text found" : "No visible text found"
                return
            }

            let preserve = Settings.bool(SettingsKey.ocrPreserveLineBreaks)
            var text = preserve ? recognition.textPreservingLineBreaks : recognition.textAsParagraph
            if text.isEmpty, let barcode = recognition.barcodes.first { text = barcode }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            var summary = "Copied \(recognition.lines.count) lines"
            if let language = recognition.language { summary += " (\(language))" }
            if !recognition.barcodes.isEmpty { summary += " · \(recognition.barcodes.count) code(s)" }
            if !recognition.links.isEmpty { summary += " · \(recognition.links.count) link(s)" }
            if !hidden.isEmpty { summary += " · hidden text excluded" }
            statusMessage = summary
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func pinToScreen() {
        guard let composite = composedImage() else { return }
        PinnedWindowController.pin(image: composite)
        statusMessage = "Pinned to screen"
    }

    /// Writes the source image plus a sidecar so this session can be reopened.
    ///
    /// The image written here is the *untouched source*. Blur and redaction are
    /// recorded in the sidecar as instructions rather than applied to the
    /// pixels, which is what makes the session re-editable — and what makes the
    /// file unsafe to send. `confirmEditableSaveHidesNothing()` is the gate.
    private func saveDocument() {
        guard let image = inputImage else { return }
        guard confirmEditableSaveHidesNothing() else { return }

        let concealing = store.items.contains { $0.tool.concealsContent }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PixCap-Editable.png"
        panel.message = concealing
            ? "Saved with a .pixcap.json sidecar. Blurred and redacted areas stay readable in this copy — export a flattened image before sharing it."
            : "The image is saved with a .pixcap.json sidecar holding your edits."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The sidecar references the untouched source, so edits stay reversible.
        guard let data = ImageExporter.data(from: image, format: .png) else {
            statusMessage = "Could not encode the source image"
            return
        }

        do {
            try data.write(to: url)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return
        }

        var configToSave = config
        configToSave.frameTitle = frameTitle.isEmpty ? nil : frameTitle

        if let sidecar = DocumentStore.save(sourceImageURL: url, config: configToSave, items: store.items) {
            statusMessage = "Saved editable copy · \(sidecar.lastPathComponent)"
        } else {
            statusMessage = "Image saved, but the sidecar could not be written"
        }
    }

    /// Warns before an editable save that would leave concealed areas readable.
    ///
    /// Returns `true` to go ahead with the editable save. Choosing to export
    /// instead runs the flattened export and returns `false`, because that path
    /// has already saved a file and the editable save must not also run.
    private func confirmEditableSaveHidesNothing() -> Bool {
        let hidden = store.items.filter { $0.tool.concealsContent }
        guard !hidden.isEmpty else { return true }

        let subject = hidden.count == 1
            ? "one blurred or redacted area"
            : "\(hidden.count) blurred or redacted areas"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This editable copy will not hide \(subject)."
        alert.informativeText = """
            An editable copy stores the original screenshot and describes your \
            edits in a sidecar file beside it. The concealment is an \
            instruction, not part of the image, so whatever you hid can still \
            be read from the saved file.

            Export a flattened image if you intend to send it to anyone.
            """
        alert.addButton(withTitle: "Export Flattened Image…")
        alert.addButton(withTitle: "Save Editable Anyway")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveToFile()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Restores a saved session when the opened image has a sidecar.
    private func restoreDocumentIfAvailable() {
        guard let sourceURL, let document = DocumentStore.load(forImage: sourceURL) else { return }

        config = document.config
        frameTitle = document.config.frameTitle ?? ""
        store.replaceAll(with: document.items)
        syncShadowOpacity()
        statusMessage = "Restored \(document.items.count) saved annotations"
    }
}

/// A single background preset chip.
@available(macOS 14.0, *)
struct PresetSwatch: View {
    let preset: BackgroundPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 8)
                .fill(preset.fill.swiftUIStyle)
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )
            Text(preset.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(preset.name)
    }
}

extension BackgroundFill {
    /// SwiftUI equivalent of the fill, used for sidebar swatches.
    var swiftUIStyle: AnyShapeStyle {
        switch self {
        case .gradient(let angle, let stops):
            let colors = stops.map { Color(NSColor(hex: $0.hex) ?? .black) }
            let radians = angle * .pi / 180
            let unit = CGPoint(x: cos(radians), y: sin(radians))
            return AnyShapeStyle(LinearGradient(
                colors: colors,
                startPoint: UnitPoint(x: 0.5 - unit.x / 2, y: 0.5 - unit.y / 2),
                endPoint: UnitPoint(x: 0.5 + unit.x / 2, y: 0.5 + unit.y / 2)
            ))
        case .solid(let hex):
            return AnyShapeStyle(Color(NSColor(hex: hex) ?? .black))
        case .glassmorphism(_, let hex, let opacity):
            return AnyShapeStyle(Color(NSColor(hex: hex) ?? .black).opacity(opacity))
        case .transparent:
            return AnyShapeStyle(.clear)
        }
    }
}

/// Renders the Rust core's SVG output.
@available(macOS 14.0, *)
struct SVGPreview: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;display:flex;align-items:center;justify-content:center;height:100%;">
        \(svg)
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

@available(macOS 14.0, *)
public final class EditorWindowController {
    private static var window: NSWindow?

    public static func openEditor(
        with image: NSImage? = nil,
        code: String = "",
        mode: String = "area",
        sourceURL: URL? = nil
    ) {
        let view = EditorWindowView(inputImage: image, captureMode: mode, sourceURL: sourceURL)

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "PixCap Beautifier Studio"
            win.center()
            win.isReleasedWhenClosed = false
            window = win
        }

        window?.contentViewController = NSHostingController(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
