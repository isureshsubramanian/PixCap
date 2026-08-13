import SwiftUI
import Cocoa

/// Floating tool palette for the annotation editor.
@available(macOS 14.0, *)
public struct AnnotationToolsView: View {
    @Binding var selectedTool: AnnotationTool
    @ObservedObject var store: AnnotationStore

    public init(selectedTool: Binding<AnnotationTool>, store: AnnotationStore) {
        self._selectedTool = selectedTool
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { tool in
                ToolButton(tool: tool, isSelected: selectedTool == tool) {
                    selectedTool = tool
                    if tool != .select { store.selectedID = nil }
                }
            }

            Divider().frame(height: 24)

            Button(action: store.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!store.canUndo)
            .help("Undo")
            .keyboardShortcut("z", modifiers: .command)

            Button(action: store.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!store.canRedo)
            .help("Redo")
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button(action: deleteSelection) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(store.selectedID == nil)
            .help("Delete selected annotation")

            Button(action: store.clear) {
                Image(systemName: "xmark.bin")
            }
            .buttonStyle(.plain)
            .disabled(store.items.isEmpty)
            .help("Remove all annotations")
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(radius: 6, y: 2)
    }

    private func deleteSelection() {
        guard let id = store.selectedID else { return }
        store.remove(id: id)
    }
}

@available(macOS 14.0, *)
struct ToolButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 15))
                Text(tool.shortcut)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .frame(width: 34, height: 34)
            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(tool.shortcut))")
        .keyboardShortcut(KeyEquivalent(Character(tool.shortcut.lowercased())), modifiers: [])
    }
}

/// Contextual options for the active tool: colour, stroke, fill, blur style.
@available(macOS 14.0, *)
public struct AnnotationOptionsBar: View {
    @Binding var tool: AnnotationTool
    @Binding var color: Color
    @Binding var strokeWidth: Double
    @Binding var filled: Bool
    @Binding var blurStyle: BlurStyle
    @Binding var blurIntensity: Double
    @Binding var textSize: Double
    @Binding var curvedArrow: Bool
    @Binding var arrowHead: ArrowHead
    @Binding var dashed: Bool

    public var body: some View {
        HStack(spacing: 14) {
            ColorPicker("", selection: $color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 40)
                .help("Annotation colour")
                .disabled(tool == .crop || tool == .spotlight)

            switch tool {
            case .crop:
                Text("Drag to crop. The original pixels are kept — reset from the sidebar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .spotlight:
                Text("Drag to highlight a region; everything else dims.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .redaction:
                Text("Solid block — the pixels underneath are gone from the export.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .blur:
                Picker("", selection: $blurStyle) {
                    ForEach(BlurStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                sliderControl(label: "Intensity", value: $blurIntensity, range: 5...60)

            case .text:
                sliderControl(label: "Size", value: $textSize, range: 12...72)

            case .arrow:
                Toggle("Curved", isOn: $curvedArrow)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)

                Picker("", selection: $arrowHead) {
                    ForEach(ArrowHead.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
                .help("Arrow head style")

                sliderControl(label: "Stroke", value: $strokeWidth, range: 1...12)

            case .rectangle, .ellipse:
                Toggle("Filled", isOn: $filled)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                Toggle("Dashed", isOn: $dashed)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                sliderControl(label: "Stroke", value: $strokeWidth, range: 1...12)

            case .line:
                Toggle("Dashed", isOn: $dashed)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                sliderControl(label: "Stroke", value: $strokeWidth, range: 1...12)

            case .select:
                Text("Click an annotation to select, drag to move, ⌫ to delete")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            default:
                sliderControl(label: "Stroke", value: $strokeWidth, range: 1...12)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sliderControl(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text("\(label): \(Int(value.wrappedValue))")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 110)
        }
    }
}
