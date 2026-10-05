import Foundation
import NeatCore

public enum StageError: Error, Sendable {
    case notImplemented(String)
    case toolMissing(String)
    case fetchFailed(String)
    /// The service said "not now" — the item is fine. Kept separate from
    /// `fetchFailed` because `Library` must not spend one of an item's two
    /// permanent attempts on someone else's quota. `retryAfter` is the
    /// service's own figure when it supplied one, never a guess.
    case rateLimited(retryAfter: Duration?, detail: String)
}

/// A stage takes an item and returns an updated item. That is the whole
/// contract. Stages know about the filesystem; `NeatCore` does not.
///
/// Every stage must be safe to re-run: check `needsRun` before doing work, and
/// write output atomically.
public protocol Stage: Sendable {
    var name: String { get }
    var version: Int { get }
    func run(_ item: Item, paths: NeatPaths) async throws -> Item
}
