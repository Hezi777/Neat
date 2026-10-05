import CoreGraphics
import Foundation
import ImageIO
import NeatCore
import UniformTypeIdentifiers

/// Re-reads frames Vision could not handle, using the Anthropic API.
///
/// There is no official Anthropic SDK for Swift, so this is raw HTTP against
/// `/v1/messages` — the documented path for unsupported languages.
public struct AnthropicOCR: Sendable {
    /// The model named in the project brief. Claude Sonnet 5 (`claude-sonnet-5`)
    /// is newer and cheaper; this stays on the requested model until asked.
    public static let model = "claude-sonnet-4-6"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    /// Frames are downscaled before upload — OCR does not need full resolution
    /// and the tokens are the cost.
    public static let maxDimension: CGFloat = 768

    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    static let prompt = """
        Transcribe every piece of text visible in this image, exactly as it appears.

        Rules:
        - Output only the transcribed text, nothing else.
        - No commentary, no description of the image, no markdown fences.
        - Preserve line breaks and reading order.
        - Keep Hebrew text in Hebrew; do not translate anything.
        - Preserve code, CLI flags and filenames character for character.
        - If there is no text at all, output exactly: (no text)
        """

    public func read(_ frame: URL) async throws -> String {
        guard let jpeg = Self.downscaledJPEG(frame) else {
            throw StageError.fetchFailed("could not read frame \(frame.lastPathComponent)")
        }

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 2048,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64",
                                "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": Self.prompt],
                ],
            ]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw StageError.fetchFailed("no response from Anthropic API")
        }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data, as: UTF8.self).prefix(300)
            throw StageError.fetchFailed("Anthropic API \(http.statusCode): \(detail)")
        }

        let text = try Self.extractText(data)
        return text == "(no text)" ? "" : text
    }

    static func extractText(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]]
        else { throw StageError.fetchFailed("unexpected Anthropic response shape") }

        return content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downscales the longest edge to `maxDimension` and re-encodes as JPEG.
    static func downscaledJPEG(_ url: URL, maxDimension: CGFloat = AnthropicOCR.maxDimension) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
