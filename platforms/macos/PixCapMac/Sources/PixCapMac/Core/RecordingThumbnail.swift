import Foundation
import AppKit
import AVFoundation
import ImageIO

/// Extracts a poster frame from a finished recording so it can appear in history.
public enum RecordingThumbnail {

    /// Returns the first usable frame of an MP4, or the first frame of a GIF.
    public static func firstFrame(of url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "gif" {
            return firstGIFFrame(of: url)
        }
        return firstVideoFrame(of: url)
    }

    private static func firstVideoFrame(of url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        // Half a second in, so a fade-in does not produce a blank thumbnail;
        // a very short recording falls back to the first frame.
        let candidates = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]

        for time in candidates {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return nil
    }

    private static func firstGIFFrame(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
