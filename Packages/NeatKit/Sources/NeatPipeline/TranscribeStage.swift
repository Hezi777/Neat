import Foundation
import NeatCore
import WhisperKit

/// Turns `media/audio.m4a` into `transcript.txt`.
///
/// The source material is mixed Hebrew and English, often code-switching
/// mid-sentence, so language is detected rather than pinned.
public struct TranscribeStage: Stage {
    public let name = "transcribe"
    public let version = StageVersions.transcribe

    /// Large enough to handle code-switching, small enough to be practical
    /// on-device. Downloaded once on first use and cached by WhisperKit.
    public static let modelName = "large-v3-v20240930_turbo_632MB"

    let modelFolder: URL?

    public init(modelFolder: URL? = nil) {
        self.modelFolder = modelFolder
    }

    public func run(_ item: Item, paths: NeatPaths) async throws -> Item {
        var item = item
        guard item.stages.transcribe.needsRun(currentVersion: version) else { return item }

        // Slideshows and image posts have no speech — background music at most.
        // Marking them skipped rather than leaving them undone is what stops the
        // resume sweep retrying them forever.
        guard item.type == .video else {
            Log.pipeline.info("\(item.id.folderName, privacy: .public): no speech to transcribe, skipping")
            item.stages.transcribe = .skippedStage(v: version)
            return item
        }

        let audio = paths.media(item.id).appending(path: "audio.m4a")
        guard FileManager.default.fileExists(atPath: audio.path()) else {
            throw StageError.fetchFailed("no audio.m4a — run fetch first")
        }

        let text = try await transcribe(audio)

        // An empty transcript is a real answer (silent clip), not a failure. It
        // is written so the stage does not re-run forever looking for speech.
        try atomicWrite(text, to: paths.transcript(item.id))

        item.stages.transcribe = .completed(v: version)
        return item
    }

    func transcribe(_ audio: URL) async throws -> String {
        let config = WhisperKitConfig(model: Self.modelName, modelFolder: modelFolder?.path())

        let pipe: WhisperKit
        do {
            pipe = try await WhisperKit(config)
        } catch {
            throw StageError.fetchFailed("WhisperKit could not load \(Self.modelName): \(error.localizedDescription)")
        }

        let results = try await pipe.transcribe(audioPath: audio.path())
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
