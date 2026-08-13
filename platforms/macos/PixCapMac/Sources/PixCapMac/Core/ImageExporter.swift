import Foundation
import AppKit
import UniformTypeIdentifiers

/// Encodes and writes images using the user's Output & Export preferences.
public enum ImageExporter {
    /// Encodes `image` in the requested format at its full pixel resolution.
    public static func data(
        from image: NSImage,
        format: Settings.ExportFormat = Settings.exportFormat
    ) -> Data? {
        guard let representation = bitmapRepresentation(of: image) else { return nil }

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if format.bitmapType == .jpeg {
            let quality = Settings.double(SettingsKey.jpgQuality)
            properties[.compressionFactor] = max(0.01, min(1.0, quality / 100.0))
        }

        return representation.representation(using: format.bitmapType, properties: properties)
    }

    /// Writes `image` into `directory`, resolving the naming pattern through the Rust core.
    ///
    /// - Returns: the URL written, or nil if encoding or writing failed.
    @discardableResult
    public static func save(
        image: NSImage,
        mode: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        directory: URL = Settings.saveDirectory,
        format: Settings.ExportFormat = Settings.exportFormat
    ) -> URL? {
        guard let data = data(from: image, format: format) else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("PixCap: could not create save directory \(directory.path): \(error.localizedDescription)")
            return nil
        }

        let baseName = PixCapBridge.shared.resolveFilename(
            pattern: Settings.namingPattern,
            mode: mode,
            appName: appName,
            windowTitle: windowTitle,
            width: Int(image.size.width),
            height: Int(image.size.height),
            counter: Settings.nextCaptureCounter()
        )

        let sanitized = sanitize(baseName)
        let suffix = Settings.bool(SettingsKey.add2xSuffix) ? "@2x" : ""
        let url = uniqueURL(
            in: directory,
            name: sanitized + suffix,
            fileExtension: format.fileExtension
        )

        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("PixCap: failed to write \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes a small thumbnail alongside the history database and returns its path.
    @discardableResult
    public static func writeThumbnail(for image: NSImage, id: String = UUID().uuidString) -> URL? {
        let directory = PixCapPaths.thumbnailDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let maxEdge: CGFloat = 480
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()

        guard let data = data(from: thumbnail, format: .png) else { return nil }
        let url = directory.appendingPathComponent("\(id).png")
        try? data.write(to: url)
        return url
    }

    public static func copyToClipboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: - Helpers

    /// Full-resolution bitmap for `image`, preserving the captured pixel dimensions.
    private static func bitmapRepresentation(of image: NSImage) -> NSBitmapImageRep? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = image.size
        return representation
    }

    /// Strips path separators and characters that are awkward in filenames.
    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\t")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "PixCap" : trimmed
    }

    /// Appends ` 2`, ` 3`, … rather than overwriting an existing file.
    private static func uniqueURL(in directory: URL, name: String, fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent("\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }
}
