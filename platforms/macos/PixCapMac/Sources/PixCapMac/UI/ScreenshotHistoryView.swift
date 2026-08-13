import SwiftUI
import Cocoa

/// Screenshot history browser backed by the Rust core's SQLite database.
@available(macOS 14.0, *)
public final class ScreenshotHistoryManager: ObservableObject {
    public static let shared = ScreenshotHistoryManager()

    @Published public private(set) var records: [ScreenshotRecord] = []

    private let store = HistoryStore.shared
    private var thumbnailCache: [Int64: NSImage] = [:]

    private init() {
        reload()
    }

    /// Records a capture: writes a thumbnail, indexes its text, then inserts a row.
    ///
    /// OCR runs off the main thread so a large capture never stalls the UI; the
    /// extracted text is what makes history search useful.
    public func add(image: NSImage, url: URL, mode: String) {
        let thumbnailURL = ImageExporter.writeThumbnail(for: image)
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let size = image.size

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ocrText: String?
            if Settings.bool(SettingsKey.ocrStoreInHistory),
               let recognition = try? OCRService.recognize(in: image, includeBarcodes: false),
               !recognition.isEmpty {
                ocrText = recognition.textPreservingLineBreaks
            }

            let record = ScreenshotRecord(
                id: 0,
                filepath: url.path,
                thumbnail_path: thumbnailURL?.path,
                captured_at: capturedAt,
                capture_mode: mode,
                width: Int64(size.width),
                height: Int64(size.height),
                ocr_text: ocrText,
                tags: nil,
                is_favorited: false
            )

            self?.store.insert(record)
            self?.reload()
        }
    }

    public func reload(query: String = "") {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = trimmed.isEmpty ? store.recent() : store.search(trimmed)
        DispatchQueue.main.async {
            self.records = results
        }
    }

    public func delete(_ record: ScreenshotRecord) {
        store.delete(id: record.id)
        thumbnailCache[record.id] = nil
        reload()
    }

    public func toggleFavorite(_ record: ScreenshotRecord) {
        store.toggleFavorite(id: record.id)
        reload()
    }

    /// The most recent capture that still exists on disk.
    public var mostRecentImage: NSImage? {
        records.lazy.compactMap { NSImage(contentsOfFile: $0.filepath) }.first
    }

    /// Thumbnail for a record, falling back to the full image, cached in memory.
    public func thumbnail(for record: ScreenshotRecord) -> NSImage? {
        if let cached = thumbnailCache[record.id] { return cached }

        let image = record.thumbnail_path.flatMap { NSImage(contentsOfFile: $0) }
            ?? NSImage(contentsOfFile: record.filepath)
        if let image { thumbnailCache[record.id] = image }
        return image
    }

    public func fullImage(for record: ScreenshotRecord) -> NSImage? {
        NSImage(contentsOfFile: record.filepath)
    }
}

@available(macOS 14.0, *)
public struct ScreenshotHistoryView: View {
    @ObservedObject private var manager = ScreenshotHistoryManager.shared
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search captures by text or tag…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { manager.reload(query: searchText) }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        manager.reload()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if manager.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No captures yet" : "No captures match “\(searchText)”")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(manager.records) { record in
                            HistoryCard(record: record, manager: manager)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: searchText) { _, value in manager.reload(query: value) }
        .onAppear { manager.reload(query: searchText) }
    }
}

@available(macOS 14.0, *)
private struct HistoryCard: View {
    let record: ScreenshotRecord
    @ObservedObject var manager: ScreenshotHistoryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = manager.thumbnail(for: record) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if record.is_favorited {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .padding(6)
                }
            }
            .onTapGesture(count: 2) { openInEditor() }

            Text(record.fileURL.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Text(record.capturedDate, format: .dateTime.day().month().hour().minute())
                if let width = record.width, let height = record.height {
                    Text("· \(width)×\(height)")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .contextMenu {
            Button("Open in Editor", action: openInEditor)
            Button("Copy Image", action: copyImage)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            }
            Button(record.is_favorited ? "Remove Favorite" : "Add Favorite") {
                manager.toggleFavorite(record)
            }
            Divider()
            Button("Delete from History", role: .destructive) {
                manager.delete(record)
            }
        }
        .help(record.filepath)
    }

    private func openInEditor() {
        guard let image = manager.fullImage(for: record) else { return }
        EditorWindowController.openEditor(with: image, mode: record.capture_mode ?? "area")
    }

    private func copyImage() {
        guard let image = manager.fullImage(for: record) else { return }
        ImageExporter.copyToClipboard(image)
    }
}

@available(macOS 14.0, *)
public final class ScreenshotHistoryWindowController {
    private static var window: NSWindow?

    public static func showWindow() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Screenshot History"
            win.contentViewController = NSHostingController(rootView: ScreenshotHistoryView())
            win.center()
            win.isReleasedWhenClosed = false
            window = win
        }

        ScreenshotHistoryManager.shared.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
