import CoreGraphics
import Foundation
import ImageIO
import NeatCore
import Vision

/// What one frame's OCR produced, and how much to trust it.
public struct FrameText: Sendable {
    public let frame: URL
    public let lines: [String]
    /// Mean confidence across recognized lines, 0 when nothing was found.
    public let confidence: Float
    public let containsNonLatin: Bool

    public var text: String { lines.joined(separator: "\n") }
    public var isEmpty: Bool { lines.isEmpty }
}

/// Local text recognition. Strong on Latin script, which covers tool names,
/// CLI flags and code — so most frames never need the API at all.
public struct VisionOCR: Sendable {
    /// Below this mean confidence a frame is re-read by the API.
    public static let lowConfidence: Float = 0.45

    public init() {}

    public func read(_ frame: URL) async throws -> FrameText {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The material is mixed Hebrew and English. Vision is asked for both,
        // and low-confidence or Hebrew-bearing frames go to the API afterwards.
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"),
                                        Locale.Language(identifier: "he-IL")]

        let observations = try await request.perform(on: frame, orientation: nil)

        var lines: [String] = []
        var total: Float = 0

        for observation in observations {
            guard let best = observation.topCandidates(1).first else { continue }
            let line = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            lines.append(line)
            total += best.confidence
        }

        let confidence = lines.isEmpty ? 0 : total / Float(lines.count)
        return FrameText(
            frame: frame,
            lines: lines,
            confidence: confidence,
            containsNonLatin: lines.contains(where: Self.hasNonLatinScript))
    }

    /// Hebrew and Arabic ranges. Vision handles these far less reliably than
    /// Latin, so their presence is a reason to re-read with the API.
    static func hasNonLatinScript(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x0590...0x05FF).contains(scalar.value)   // Hebrew
                || (0x0600...0x06FF).contains(scalar.value)  // Arabic
        }
    }

    /// Whether this frame is worth spending an API call on.
    public static func needsFallback(_ result: FrameText) -> Bool {
        result.isEmpty || result.confidence < lowConfidence || result.containsNonLatin
    }
}
