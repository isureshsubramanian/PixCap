import Foundation
import AppKit
import Vision

/// Text and barcode recognition using Apple's Vision framework.
///
/// Everything runs on-device; no image or extracted text leaves the machine.
public enum OCRService {

    public struct TextLine {
        public let text: String
        /// Normalised bounding box (origin bottom-left, Vision's convention).
        public let boundingBox: CGRect
        public let confidence: Float
    }

    public struct Recognition {
        public let lines: [TextLine]
        /// Detected language identifier, when Vision reports one.
        public let language: String?
        public let barcodes: [String]

        /// Lines joined with newlines, preserving the visual layout.
        public var textPreservingLineBreaks: String {
            lines.map(\.text).joined(separator: "\n")
        }

        /// Lines joined into flowing text, with hyphenated line breaks repaired.
        public var textAsParagraph: String {
            var result = ""
            for line in lines {
                if result.isEmpty {
                    result = line.text
                } else if result.hasSuffix("-") {
                    result.removeLast()
                    result += line.text
                } else {
                    result += " " + line.text
                }
            }
            return result
        }

        public var isEmpty: Bool { lines.isEmpty && barcodes.isEmpty }

        /// A copy with every line a concealing region covers removed.
        ///
        /// `regions` are in image space — origin top-left, measured in image
        /// points — because that is how annotations are stored. Vision reports
        /// normalised boxes with the origin bottom-left, so the conversion
        /// happens here, next to the convention it depends on.
        ///
        /// A line goes when a fifth of it is covered: enough to survive merely
        /// grazing the edge of a redaction, strict enough that a partly hidden
        /// line is not handed over. Overlapping regions are summed without
        /// deduplication, which can only over-estimate coverage — it errs
        /// toward dropping a line, which is the safe direction here.
        ///
        /// Barcodes are not filtered. Vision does not report their geometry
        /// through this path, so their position cannot be checked.
        public func excludingText(coveredBy regions: [CGRect], imageSize: CGSize) -> Recognition {
            guard !regions.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return self }

            let kept = lines.filter { line in
                let box = line.boundingBox
                let imageSpace = CGRect(
                    x: box.minX * imageSize.width,
                    y: (1 - box.maxY) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                )

                let area = imageSpace.width * imageSpace.height
                guard area > 0 else { return true }

                let covered = regions.reduce(CGFloat.zero) { running, region in
                    let overlap = region.intersection(imageSpace)
                    return overlap.isNull ? running : running + overlap.width * overlap.height
                }

                return covered / area < 0.2
            }

            return Recognition(lines: kept, language: language, barcodes: barcodes)
        }

        /// URLs and bare domains found in the recognised text.
        public var links: [String] {
            let text = textPreservingLineBreaks
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return []
            }

            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, options: [], range: range)
            var seen = Set<String>()

            return matches.compactMap { match in
                guard let url = match.url?.absoluteString, seen.insert(url).inserted else { return nil }
                return url
            }
        }
    }

    public enum OCRError: LocalizedError {
        case noImageData
        case recognitionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noImageData: return "The image could not be read for text recognition."
            case .recognitionFailed(let reason): return "Text recognition failed: \(reason)"
            }
        }
    }

    /// Recognises text and barcodes in `image`.
    ///
    /// - Parameter languages: preferred recognition languages; empty uses
    ///   Vision's automatic language detection.
    public static func recognize(
        in image: NSImage,
        languages: [String] = [],
        includeBarcodes: Bool = true
    ) throws -> Recognition {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw OCRError.noImageData
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        if languages.isEmpty {
            textRequest.automaticallyDetectsLanguage = true
        } else {
            textRequest.recognitionLanguages = languages
        }

        let barcodeRequest = VNDetectBarcodesRequest()

        do {
            try handler.perform(includeBarcodes ? [textRequest, barcodeRequest] : [textRequest])
        } catch {
            throw OCRError.recognitionFailed(error.localizedDescription)
        }

        let observations = textRequest.results ?? []

        // Vision returns observations in reading order per region, but a
        // multi-column layout can interleave; sorting top-to-bottom then
        // left-to-right restores the visual order.
        let sorted = observations.sorted { first, second in
            let firstTop = first.boundingBox.maxY
            let secondTop = second.boundingBox.maxY
            if abs(firstTop - secondTop) > 0.01 { return firstTop > secondTop }
            return first.boundingBox.minX < second.boundingBox.minX
        }

        let lines: [TextLine] = sorted.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextLine(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }

        let barcodes: [String] = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)

        return Recognition(
            lines: lines,
            language: detectedLanguage(from: lines),
            barcodes: Array(Set(barcodes))
        )
    }

    /// Recognises text and copies it to the clipboard.
    ///
    /// - Returns: the text placed on the clipboard, or nil when nothing was found.
    @discardableResult
    public static func recognizeAndCopy(in image: NSImage, preserveLineBreaks: Bool = true) -> String? {
        guard let recognition = try? recognize(in: image), !recognition.isEmpty else { return nil }

        var text = preserveLineBreaks ? recognition.textPreservingLineBreaks : recognition.textAsParagraph
        if text.isEmpty, let barcode = recognition.barcodes.first {
            text = barcode
        }
        guard !text.isEmpty else { return nil }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// Best-effort language identification over the recognised text.
    private static func detectedLanguage(from lines: [TextLine]) -> String? {
        let sample = lines.prefix(12).map(\.text).joined(separator: " ")
        guard sample.count > 8 else { return nil }
        return NSLinguisticTagger.dominantLanguage(for: sample)
    }
}
