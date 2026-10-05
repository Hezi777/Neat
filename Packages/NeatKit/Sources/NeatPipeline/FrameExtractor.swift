import Foundation
import NeatCore

/// Fills `frames/`.
///
/// This is the only place the item type changes what happens. Everything
/// downstream reads `frames/` and never branches on type.
public struct FrameExtractor: Sendable {
    public static let videoKeyframeCap = 8
    public static let sceneThreshold = 0.3
    /// If scene detection finds fewer than this, fall back to a fixed interval.
    public static let minKeyframes = 3
    public static let fallbackInterval = 3.0

    let runner: ProcessRunner
    let ffmpeg: String

    public init(runner: ProcessRunner = ProcessRunner(), ffmpeg: String) {
        self.runner = runner
        self.ffmpeg = ffmpeg
    }

    static func frameName(_ index: Int) -> String {
        String(format: "frame-%02d.jpg", index)
    }

    /// Video: scene-change detection, capped, with a fixed-interval fallback so
    /// a static talking-head clip still yields something to OCR.
    public func extractFromVideo(_ video: URL, into frames: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        try await runScenePass(video, into: frames, threshold: Self.sceneThreshold)
        var count = try countFrames(in: frames)

        if count < Self.minKeyframes {
            Log.pipeline.notice("scene detection found \(count) frames, falling back to fixed interval")
            try clearFrames(in: frames)
            try await runIntervalPass(video, into: frames, interval: Self.fallbackInterval)
            count = try countFrames(in: frames)
        }

        if count > Self.videoKeyframeCap {
            try trimFrames(in: frames, to: Self.videoKeyframeCap)
            count = Self.videoKeyframeCap
        }
        return count
    }

    /// Slideshow rendered as an mp4: every slide transition is an abrupt cut, so
    /// scene detection is the right tool — but there is no cap, because losing
    /// slides loses the tutorial.
    public func extractFromSlideshowVideo(_ video: URL, into frames: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try await runScenePass(video, into: frames, threshold: 0.15)
        var count = try countFrames(in: frames)

        if count < 1 {
            try await runIntervalPass(video, into: frames, interval: 2.0)
            count = try countFrames(in: frames)
        }
        return count
    }

    /// Slideshow or image post delivered as image URLs: every one is a frame.
    public func download(images urls: [URL], into frames: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        var written = 0
        for (index, url) in urls.enumerated() {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !data.isEmpty else { continue }
                try data.write(to: frames.appending(path: Self.frameName(index)), options: .atomic)
                written += 1
            } catch {
                // One unreachable slide must not lose the other five.
                Log.pipeline.error("slide \(index) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    // MARK: - ffmpeg passes

    func runScenePass(_ video: URL, into frames: URL, threshold: Double) async throws {
        try await runner.runChecked(ffmpeg, [
            "-nostdin", "-y", "-i", video.path(),
            "-vf", "select=gt(scene\\,\(threshold)),scale=1280:-2",
            // -fps_mode replaced -vsync, which ffmpeg 9 removed outright.
            "-fps_mode", "vfr", "-q:v", "3",
            Self.outputPattern(in: frames),
        ])
    }

    func runIntervalPass(_ video: URL, into frames: URL, interval: Double) async throws {
        try await runner.runChecked(ffmpeg, [
            "-nostdin", "-y", "-i", video.path(),
            "-vf", "fps=1/\(interval),scale=1280:-2",
            "-q:v", "3",
            Self.outputPattern(in: frames),
        ])
    }

    /// ffmpeg's numbering pattern, built as a plain string.
    ///
    /// `URL.appending(path:)` percent-encodes the `%`, which hands ffmpeg
    /// `frame-%2502d.jpg` and makes it fail with an unhelpful argument error.
    static func outputPattern(in frames: URL) -> String {
        frames.path().hasSuffix("/") ? frames.path() + "frame-%02d.jpg"
                                     : frames.path() + "/frame-%02d.jpg"
    }

    // MARK: - frame bookkeeping

    func frameFiles(in frames: URL) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(
            at: frames, includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path() < $1.path() }
    }

    func countFrames(in frames: URL) throws -> Int {
        (try? frameFiles(in: frames).count) ?? 0
    }

    func clearFrames(in frames: URL) throws {
        for file in (try? frameFiles(in: frames)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Keeps an evenly spread subset rather than the first N, so a capped video
    /// still represents its whole length.
    func trimFrames(in frames: URL, to cap: Int) throws {
        let files = try frameFiles(in: frames)
        guard files.count > cap else { return }

        let keepIndices = Set((0..<cap).map { Int(round(Double($0) * Double(files.count - 1) / Double(cap - 1))) })
        var kept: [URL] = []
        for (i, file) in files.enumerated() {
            if keepIndices.contains(i) { kept.append(file) } else { try? FileManager.default.removeItem(at: file) }
        }
        // Renumber so frames are always frame-00..frame-NN with no gaps.
        for (i, file) in kept.enumerated() {
            let target = frames.appending(path: Self.frameName(i))
            if file != target { try? FileManager.default.moveItem(at: file, to: target) }
        }
    }
}
