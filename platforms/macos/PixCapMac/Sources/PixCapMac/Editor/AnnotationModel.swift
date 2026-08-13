import Foundation
import AppKit
import SwiftUI

/// Tools available in the annotation toolbar.
///
/// Coordinates for every annotation are stored in *image space*: origin at the
/// top-left of the captured screenshot, measured in image points. That keeps the
/// model independent of preview zoom, so the same items render identically in
/// the on-screen preview and in the full-resolution export.
public enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case crop
    case arrow
    case line
    case rectangle
    case ellipse
    case freehand
    case highlight
    case text
    case counter
    case blur
    case redaction
    case spotlight

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .counter: return "number.circle"
        case .blur: return "drop.halffull"
        case .redaction: return "rectangle.fill"
        case .spotlight: return "light.max"
        }
    }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .freehand: return "Draw"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .counter: return "Counter"
        case .blur: return "Blur"
        case .redaction: return "Redaction"
        case .spotlight: return "Spotlight"
        }
    }

    /// Single-key shortcut, matching the shortcuts listed in Preferences.
    public var shortcut: String {
        switch self {
        case .select: return "V"
        case .crop: return "K"
        case .arrow: return "A"
        case .line: return "L"
        case .rectangle: return "R"
        case .ellipse: return "E"
        case .freehand: return "D"
        case .highlight: return "M"
        case .text: return "T"
        case .counter: return "C"
        case .blur: return "B"
        case .redaction: return "P"
        case .spotlight: return "H"
        }
    }

    /// Tools that are placed with a single click rather than dragged out.
    public var isPointPlaced: Bool {
        self == .counter || self == .text
    }

    /// Tools that modify the canvas rather than adding an item to the layer.
    public var isCanvasOperation: Bool {
        self == .crop
    }
}

public enum BlurStyle: String, CaseIterable, Codable {
    case gaussian = "Blur"
    case pixelate = "Pixelate"
}

public enum ArrowHead: String, CaseIterable, Codable {
    case filled
    case open
    case none

    public var title: String {
        switch self {
        case .filled: return "Filled"
        case .open: return "Open"
        case .none: return "None"
        }
    }
}

/// One drawn annotation.
public struct AnnotationItem: Identifiable, Equatable {
    public let id: UUID
    public var tool: AnnotationTool
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint]
    public var colorHex: String
    public var strokeWidth: CGFloat
    public var filled: Bool
    public var text: String
    public var fontSize: CGFloat
    public var number: Int
    public var blurStyle: BlurStyle
    public var blurIntensity: CGFloat
    public var curvedArrow: Bool
    public var arrowHead: ArrowHead
    public var dashed: Bool
    /// How far the area outside a spotlight is dimmed (0–1).
    public var spotlightDim: CGFloat

    public init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = [],
        colorHex: String,
        strokeWidth: CGFloat,
        filled: Bool = false,
        text: String = "",
        fontSize: CGFloat = 24,
        number: Int = 1,
        blurStyle: BlurStyle = .gaussian,
        blurIntensity: CGFloat = 20,
        curvedArrow: Bool = true,
        arrowHead: ArrowHead = .filled,
        dashed: Bool = false,
        spotlightDim: CGFloat = 0.65
    ) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
        self.points = points
        self.colorHex = colorHex
        self.strokeWidth = strokeWidth
        self.filled = filled
        self.text = text
        self.fontSize = fontSize
        self.number = number
        self.blurStyle = blurStyle
        self.blurIntensity = blurIntensity
        self.curvedArrow = curvedArrow
        self.arrowHead = arrowHead
        self.dashed = dashed
        self.spotlightDim = spotlightDim
    }

    public var color: NSColor {
        NSColor(hex: colorHex) ?? .systemRed
    }

    /// Normalised bounding rectangle in image space.
    public var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Whether the item covers enough area to be worth keeping after a drag.
    public var isMeaningful: Bool {
        switch tool {
        case .counter:
            return true
        case .text:
            return !text.isEmpty
        case .freehand:
            return points.count > 1
        case .line, .arrow:
            return hypot(end.x - start.x, end.y - start.y) > 4
        default:
            return rect.width > 4 && rect.height > 4
        }
    }

    /// Hit-test area used by the select tool, padded so thin strokes stay grabbable.
    public func hitRect() -> CGRect {
        let padding = max(strokeWidth, 8)
        switch tool {
        case .counter:
            let radius = counterRadius
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        case .text:
            let size = textSize()
            return CGRect(x: start.x, y: start.y, width: size.width, height: size.height).insetBy(dx: -padding, dy: -padding)
        case .freehand:
            guard let first = points.first else { return .zero }
            var bounds = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
            return bounds.insetBy(dx: -padding, dy: -padding)
        default:
            return rect.insetBy(dx: -padding, dy: -padding)
        }
    }

    public var counterRadius: CGFloat { max(14, strokeWidth * 6) }

    public func textAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color
        ]
    }

    public func textSize() -> CGSize {
        let string = text.isEmpty ? " " : text
        return (string as NSString).size(withAttributes: textAttributes())
    }

    /// Returns a copy translated by `delta` (used by the select tool).
    public func moved(by delta: CGSize) -> AnnotationItem {
        var copy = self
        copy.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        copy.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }
}

/// Holds the annotation list plus undo/redo history for one editor session.
public final class AnnotationStore: ObservableObject {
    @Published public private(set) var items: [AnnotationItem] = []
    @Published public var selectedID: UUID?
    /// Item currently being typed into by the text tool.
    @Published public var editingID: UUID?

    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The next counter value, continuing from the highest bubble already placed.
    public var nextCounterNumber: Int {
        let start = max(1, Settings.int(SettingsKey.counterStartNumber))
        let highest = items.filter { $0.tool == .counter }.map(\.number).max()
        return highest.map { $0 + 1 } ?? start
    }

    public func add(_ item: AnnotationItem) {
        checkpoint()
        items.append(item)
    }

    public func update(id: UUID, checkpointFirst: Bool = true, _ mutate: (inout AnnotationItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if checkpointFirst { checkpoint() }
        mutate(&items[index])
    }

    public func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        checkpoint()
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        if editingID == id { editingID = nil }
    }

    public func item(withID id: UUID) -> AnnotationItem? {
        items.first { $0.id == id }
    }

    /// Topmost item whose hit area contains `point` (image space).
    public func hitTest(_ point: CGPoint) -> AnnotationItem? {
        items.reversed().first { $0.hitRect().contains(point) }
    }

    public func clear() {
        guard !items.isEmpty else { return }
        checkpoint()
        items.removeAll()
        selectedID = nil
        editingID = nil
    }

    /// Replaces the whole layer, e.g. when loading a saved document.
    public func replaceAll(with newItems: [AnnotationItem], resetHistory: Bool = true) {
        if resetHistory {
            undoStack.removeAll()
            redoStack.removeAll()
        } else {
            checkpoint()
        }
        items = newItems
        selectedID = nil
        editingID = nil
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        pruneSelection()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        pruneSelection()
    }

    /// Snapshots current state for undo. Call before any mutation.
    public func checkpoint() {
        undoStack.append(items)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func pruneSelection() {
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if let editingID, !items.contains(where: { $0.id == editingID }) {
            self.editingID = nil
        }
    }
}
