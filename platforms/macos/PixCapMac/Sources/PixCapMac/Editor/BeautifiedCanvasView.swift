import SwiftUI
import AppKit

/// Interactive WYSIWYG editing surface.
///
/// The committed state is drawn by `BeautifierRenderer` — the exact routine used
/// for export — while the shape currently under the cursor is drawn as a
/// lightweight overlay so dragging stays responsive.
@available(macOS 14.0, *)
public struct BeautifiedCanvasView: View {
    let image: NSImage
    @ObservedObject var store: AnnotationStore
    let config: BeautifyConfig

    @Binding var tool: AnnotationTool
    @Binding var strokeColor: Color
    @Binding var strokeWidth: Double
    @Binding var filled: Bool
    @Binding var blurStyle: BlurStyle
    @Binding var blurIntensity: Double
    @Binding var textSize: Double
    @Binding var curvedArrow: Bool
    @Binding var arrowHead: ArrowHead
    @Binding var dashed: Bool
    /// Receives a crop rectangle drawn with the crop tool.
    let onCrop: (CGRect) -> Void

    @State private var rendered: NSImage?
    @State private var draft: AnnotationItem?
    @State private var cropDraft: CGRect?
    @State private var moveAnchor: CGPoint?
    @State private var editingText: String = ""

    public init(
        image: NSImage,
        store: AnnotationStore,
        config: BeautifyConfig,
        tool: Binding<AnnotationTool>,
        strokeColor: Binding<Color>,
        strokeWidth: Binding<Double>,
        filled: Binding<Bool>,
        blurStyle: Binding<BlurStyle>,
        blurIntensity: Binding<Double>,
        textSize: Binding<Double>,
        curvedArrow: Binding<Bool>,
        arrowHead: Binding<ArrowHead>,
        dashed: Binding<Bool>,
        onCrop: @escaping (CGRect) -> Void
    ) {
        self.image = image
        self.store = store
        self.config = config
        self._tool = tool
        self._strokeColor = strokeColor
        self._strokeWidth = strokeWidth
        self._filled = filled
        self._blurStyle = blurStyle
        self._blurIntensity = blurIntensity
        self._textSize = textSize
        self._curvedArrow = curvedArrow
        self._arrowHead = arrowHead
        self._dashed = dashed
        self.onCrop = onCrop
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = BeautifierRenderer.layout(imageSize: image.size, config: config)
            let fit = displayScale(canvas: layout.canvasSize, available: geometry.size)
            let displaySize = CGSize(width: layout.canvasSize.width * fit, height: layout.canvasSize.height * fit)

            ZStack(alignment: .topLeading) {
                CheckerboardBackground()

                if let rendered {
                    Image(nsImage: rendered)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                } else {
                    ProgressView().frame(width: displaySize.width, height: displaySize.height)
                }

                overlay(layout: layout, fit: fit)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(layout: layout, fit: fit))

                if let editingID = store.editingID, let item = store.item(withID: editingID) {
                    textEditor(for: item, layout: layout, fit: fit)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { refresh() }
            .onChange(of: config) { _, _ in refresh() }
            .onChange(of: store.items) { _, _ in refresh() }
        }
    }

    /// Fits the canvas into the available area without ever upscaling past 1:1.
    private func displayScale(canvas: CGSize, available: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(available.width / canvas.width, available.height / canvas.height, 1)
    }

    private func refresh() {
        rendered = BeautifierRenderer.render(
            image: image,
            annotations: store.items,
            config: config,
            scale: Settings.renderScale()
        )
    }

    /// Full-resolution composite for saving, copying, or sharing.
    public func exportImage() -> NSImage? {
        BeautifierRenderer.render(image: image, annotations: store.items, config: config, scale: Settings.renderScale())
    }

    // MARK: - Overlay

    private func overlay(layout: BeautifyLayout, fit: CGFloat) -> some View {
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.saveGState()
                cg.scaleBy(x: fit, y: fit)
                // Match the renderer: annotation space is the uncropped image.
                cg.translateBy(
                    x: layout.imageRect.minX - layout.cropOrigin.x,
                    y: layout.imageRect.minY - layout.cropOrigin.y
                )

                let imageBounds = CGRect(
                    x: layout.cropOrigin.x,
                    y: layout.cropOrigin.y,
                    width: layout.imageRect.width,
                    height: layout.imageRect.height
                )

                if let cropDraft {
                    drawRegionOutline(cropDraft, in: cg, color: .white)
                }

                if let draft {
                    if draft.tool == .blur {
                        drawRegionOutline(draft.rect, in: cg, color: draft.color)
                    } else {
                        BeautifierRenderer.draw(draft, in: cg, imageBounds: imageBounds)
                    }
                }

                if let selectedID = store.selectedID, let item = store.item(withID: selectedID) {
                    drawRegionOutline(item.hitRect(), in: cg, color: NSColor.controlAccentColor)
                }

                // Blur regions have no stroke of their own; outline them so they stay findable.
                for item in store.items where item.tool == .blur {
                    drawRegionOutline(item.rect, in: cg, color: NSColor.white.withAlphaComponent(0.5))
                }

                cg.restoreGState()
            }
        }
        .allowsHitTesting(true)
    }

    private func drawRegionOutline(_ rect: CGRect, in context: CGContext, color: NSColor) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect)
        context.restoreGState()
    }

    // MARK: - Interaction

    private func dragGesture(layout: BeautifyLayout, fit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = imagePoint(value.startLocation, layout: layout, fit: fit)
                let current = imagePoint(value.location, layout: layout, fit: fit)

                switch tool {
                case .select:
                    handleSelectDrag(start: start, current: current)
                case .text, .counter:
                    break // placed on release
                case .crop:
                    cropDraft = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y)
                    )
                default:
                    draft = makeDraft(start: start, current: current)
                }
            }
            .onEnded { value in
                let start = imagePoint(value.startLocation, layout: layout, fit: fit)
                let end = imagePoint(value.location, layout: layout, fit: fit)

                switch tool {
                case .select:
                    moveAnchor = nil
                case .crop:
                    if let rect = cropDraft, rect.width > 8, rect.height > 8 {
                        onCrop(rect)
                    }
                    cropDraft = nil
                case .counter:
                    store.add(AnnotationItem(
                        tool: .counter,
                        start: end,
                        end: end,
                        colorHex: NSColor(strokeColor).hexString,
                        strokeWidth: CGFloat(strokeWidth),
                        number: store.nextCounterNumber
                    ))
                case .text:
                    let item = AnnotationItem(
                        tool: .text,
                        start: end,
                        end: end,
                        colorHex: NSColor(strokeColor).hexString,
                        strokeWidth: CGFloat(strokeWidth),
                        fontSize: CGFloat(textSize)
                    )
                    store.add(item)
                    editingText = ""
                    store.editingID = item.id
                default:
                    if let draft, draft.isMeaningful {
                        store.add(draft)
                    }
                    draft = nil
                    _ = start
                }
            }
    }

    private func handleSelectDrag(start: CGPoint, current: CGPoint) {
        if moveAnchor == nil {
            if let hit = store.hitTest(start) {
                store.selectedID = hit.id
                store.checkpoint()
            } else {
                store.selectedID = nil
            }
            moveAnchor = start
        }

        guard let anchor = moveAnchor, let selectedID = store.selectedID else { return }
        let delta = CGSize(width: current.x - anchor.x, height: current.y - anchor.y)
        guard delta != .zero else { return }

        // The checkpoint was taken once when the drag began, so each frame just moves.
        store.update(id: selectedID, checkpointFirst: false) { item in
            item = item.moved(by: delta)
        }
        moveAnchor = current
    }

    private func makeDraft(start: CGPoint, current: CGPoint) -> AnnotationItem {
        // Redaction blocks default to the colour chosen in Privacy settings.
        let colorHex = tool == .redaction
            ? Settings.string(SettingsKey.redactionColorHex, default: "#000000")
            : NSColor(strokeColor).hexString

        var item = AnnotationItem(
            tool: tool,
            start: start,
            end: current,
            colorHex: colorHex,
            strokeWidth: CGFloat(strokeWidth),
            filled: filled,
            fontSize: CGFloat(textSize),
            blurStyle: blurStyle,
            blurIntensity: CGFloat(blurIntensity),
            curvedArrow: curvedArrow,
            arrowHead: arrowHead,
            dashed: dashed
        )

        if tool == .freehand {
            var points = draft?.points ?? [start]
            points.append(current)
            item.points = points
        }

        return item
    }

    /// Converts a point in the displayed canvas into uncropped image space.
    private func imagePoint(_ point: CGPoint, layout: BeautifyLayout, fit: CGFloat) -> CGPoint {
        let canvasPoint = CGPoint(x: point.x / fit, y: point.y / fit)
        let raw = CGPoint(
            x: canvasPoint.x - layout.imageRect.minX + layout.cropOrigin.x,
            y: canvasPoint.y - layout.imageRect.minY + layout.cropOrigin.y
        )
        return CGPoint(
            x: min(max(layout.cropOrigin.x, raw.x), layout.cropOrigin.x + layout.imageRect.width),
            y: min(max(layout.cropOrigin.y, raw.y), layout.cropOrigin.y + layout.imageRect.height)
        )
    }

    // MARK: - Text entry

    private func textEditor(for item: AnnotationItem, layout: BeautifyLayout, fit: CGFloat) -> some View {
        let x = (layout.imageRect.minX + item.start.x) * fit
        let y = (layout.imageRect.minY + item.start.y) * fit

        return TextField("Type, then press ↩", text: $editingText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .offset(x: x, y: y)
            .onSubmit { commitText(for: item) }
            .onExitCommand { cancelText(for: item) }
            .onAppear { editingText = item.text }
    }

    private func commitText(for item: AnnotationItem) {
        let value = editingText
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.remove(id: item.id)
        } else {
            store.update(id: item.id, checkpointFirst: false) { $0.text = value }
        }
        store.editingID = nil
        editingText = ""
    }

    private func cancelText(for item: AnnotationItem) {
        if item.text.isEmpty {
            store.remove(id: item.id)
        }
        store.editingID = nil
        editingText = ""
    }
}

/// Transparency checkerboard shown behind alpha canvases.
@available(macOS 14.0, *)
struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column) % 2 == 0 {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: tile, height: tile)),
                            with: .color(Color(white: 0.84))
                        )
                    }
                    x += tile
                    column += 1
                }
                y += tile
                row += 1
            }
        }
        .opacity(0.6)
        .allowsHitTesting(false)
    }
}
