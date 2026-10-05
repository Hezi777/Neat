import Foundation

/// Which service an item came from.
public enum Platform: String, Codable, Sendable, CaseIterable {
    case tiktok
    case threads
}

/// The identity of an item, and the name of its folder on disk.
///
/// Dedup is by construction: the folder is named after the canonical ID, so the
/// same post can never land twice. Everything upstream — short links, tracking
/// params, the several TikTok URL shapes — normalizes down to this.
public struct CanonicalID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let platform: Platform

    /// The service's own ID. For TikTok this is the numeric video ID.
    public let nativeID: String

    public init(platform: Platform, nativeID: String) {
        self.platform = platform
        self.nativeID = nativeID
    }

    /// `tiktok-7381234567890` — also the folder name under `items/`.
    public var folderName: String { "\(platform.rawValue)-\(nativeID)" }

    public var description: String { folderName }
}

extension CanonicalID {
    /// Parses `tiktok-7381234567890` back into an ID. Used when reading the
    /// ledger and when scanning `items/` off disk.
    public init?(folderName: String) {
        guard let dash = folderName.firstIndex(of: "-") else { return nil }
        guard let platform = Platform(rawValue: String(folderName[..<dash])) else { return nil }
        let native = String(folderName[folderName.index(after: dash)...])
        guard !native.isEmpty else { return nil }
        self.init(platform: platform, nativeID: native)
    }
}
