import Foundation
import NeatCore

/// Reads the text that was on screen, across every file in `frames/`.
///
/// On both platforms the substance is usually on screen rather than in the
/// audio, so this stage is not optional and never silently no-ops.
///
/// Vision does the work locally. Only frames it could not read confidently —
/// or that carry non-Latin script it handles poorly — cost an API call.
public struct OnscreenStage: Stage {
    public let name = "onscreen"
    public let version = StageVersions.onscreen

    let vision: VisionOCR
    /// Every stage resolves credentials the same way: environment, then
    /// `~/Neat/.env`, then the Keychain. Reading the Keychain directly here
    /// made a key in `.env` silently dead for this stage alone.
    let secrets: SecretsStore
    /// Injectable so the fallback can be tested without a live key.
    let makeFallback: @Sendable (String) -> AnthropicOCR

    public init(
        vision: VisionOCR = VisionOCR(),
        secrets: SecretsStore = SecretsStore(),
        makeFallback: @escaping @Sendable (String) -> AnthropicOCR = { AnthropicOCR(apiKey: $0) }
    ) {
        self.vision = vision
        self.secrets = secrets
        self.makeFallback = makeFallback
    }

    public func run(_ item: Item, paths: NeatPaths) async throws -> Item {
        var item = item
        guard item.stages.onscreen.needsRun(currentVersion: version) else { return item }

        let framesDir = paths.frames(item.id)
        let frames = Self.frameFiles(in: framesDir)

        guard !frames.isEmpty else {
            // Empty frames/ is ambiguous by itself: either fetch hasn't
            // produced anything (a real failure — throw so the item keeps
            // retrying), or fetch finished and there was genuinely nothing to
            // read. The only case where fetch legitimately finishes with an
            // empty frames/ is a text-only Threads post — `runThreads` skips
            // downloading attachments entirely when there are none. Guarding
            // on `stages.fetch.done` (not just platform) keeps a Threads post
            // whose fetch actually failed from being mistaken for that case.
            if item.platform == .threads && item.stages.fetch.done {
                item.stages.onscreen = .skippedStage(v: version)
                return item
            }
            throw StageError.fetchFailed("no frames to read — run fetch first")
        }

        let apiKey = secrets.value(for: .anthropic)
        var sections: [String] = []

        for frame in frames {
            let local = try await vision.read(frame)
            var text = local.text

            if VisionOCR.needsFallback(local) {
                if let apiKey {
                    do {
                        let better = try await makeFallback(apiKey).read(frame)
                        // Only take the API's answer if it actually found more.
                        if better.count >= text.count { text = better }
                    } catch {
                        // The local read still stands; a failed fallback must
                        // not lose the text Vision already recognised.
                        Log.pipeline.error("API fallback failed for \(frame.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    Log.pipeline.notice("no API key set; keeping low-confidence local read for \(frame.lastPathComponent, privacy: .public)")
                }
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // The file's own name, not the loop index: `frames/` starts at
            // frame-01, so an index labelled frame-01.jpg as "frame 00" and
            // nothing downstream could match a section back to its image.
            sections.append("--- \(frame.deletingPathExtension().lastPathComponent) ---\n\(trimmed)")
        }

        // An empty result is a real answer — some clips genuinely carry no text.
        // It is written so the stage does not re-run forever looking for some.
        try atomicWrite(sections.joined(separator: "\n\n"), to: paths.onscreen(item.id))

        item.stages.onscreen = .completed(v: version)
        return item
    }

    static func frameFiles(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]
        return all
            .filter { imageTypes.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
