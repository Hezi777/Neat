import Foundation

/// What kind of media the item turned out to be.
///
/// Set from what `yt-dlp` actually returned, never guessed from the URL shape.
public enum ItemType: String, Codable, Sendable {
    case video
    case slideshow
    case image
}

/// One stage's state within an item.
///
/// `done` and `skipped` are distinct: `skipped` means the stage does not apply
/// to this item (a slideshow has no speech to transcribe) and must never be
/// retried by the resume sweep.
public struct StageState: Codable, Sendable, Equatable {
    public var done: Bool
    public var skipped: Bool
    /// The `StageVersions` constant this run was produced by.
    public var v: Int
    public var at: Date?
    /// Last failure message, kept so a dead item can explain itself.
    public var error: String?

    public init(done: Bool = false, skipped: Bool = false, v: Int = 0, at: Date? = nil, error: String? = nil) {
        self.done = done
        self.skipped = skipped
        self.v = v
        self.at = at
        self.error = error
    }

    /// A stage needs running unless it finished at the current version.
    /// Bumping the version constant makes exactly that stage re-run library-wide.
    public func needsRun(currentVersion: Int) -> Bool {
        if skipped { return false }
        return !done || v < currentVersion
    }

    public static func completed(v: Int, at: Date = .neatNow) -> StageState {
        StageState(done: true, v: v, at: at.neatTruncated)
    }

    public static func skippedStage(v: Int, at: Date = .neatNow) -> StageState {
        StageState(done: false, skipped: true, v: v, at: at.neatTruncated)
    }
}

public struct Stages: Codable, Sendable, Equatable {
    public var fetch: StageState
    public var transcribe: StageState
    public var onscreen: StageState
    public var extract: StageState

    public init(
        fetch: StageState = StageState(),
        transcribe: StageState = StageState(),
        onscreen: StageState = StageState(),
        extract: StageState = StageState()
    ) {
        self.fetch = fetch
        self.transcribe = transcribe
        self.onscreen = onscreen
        self.extract = extract
    }

    /// Written by hand only so that `extract` can be absent: every `item.json`
    /// on disk predates the stage, and the folder wins over anything else, so a
    /// missing key has to decode as "not run yet" rather than fail the whole item.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetch = try c.decodeIfPresent(StageState.self, forKey: .fetch) ?? StageState()
        transcribe = try c.decodeIfPresent(StageState.self, forKey: .transcribe) ?? StageState()
        onscreen = try c.decodeIfPresent(StageState.self, forKey: .onscreen) ?? StageState()
        extract = try c.decodeIfPresent(StageState.self, forKey: .extract) ?? StageState()
    }
}

/// Stage version constants.
///
/// Bump one of these to force exactly that stage to re-run across the whole
/// library on the next sweep, leaving every other stage's output intact.
public enum StageVersions {
    public static let fetch = 1
    public static let transcribe = 1
    public static let onscreen = 2  // 2: sections are labelled by frame filename
    public static let extract = 1
}

/// The contents of `item.json`.
public struct Item: Codable, Sendable, Equatable {
    public var id: CanonicalID
    public var url: String
    public var platform: Platform
    public var type: ItemType?
    public var author: String?
    public var caption: String?
    public var uploadDate: Date?
    /// Position in the pasted batch, so original ordering survives.
    public var savedRank: Int?
    public var stages: Stages

    public init(
        id: CanonicalID,
        url: String,
        platform: Platform,
        type: ItemType? = nil,
        author: String? = nil,
        caption: String? = nil,
        uploadDate: Date? = nil,
        savedRank: Int? = nil,
        stages: Stages = Stages()
    ) {
        self.id = id
        self.url = url
        self.platform = platform
        self.type = type
        self.author = author
        self.caption = caption
        self.uploadDate = uploadDate
        self.savedRank = savedRank
        self.stages = stages
    }
}
