import Foundation
import NeatCore

public enum AdapterError: Error, Sendable, Equatable {
    case notImplemented(String)
    case unrecognizedURL(String)
    case redirectFailed(String)
}

/// The one seam between "a service" and the rest of Neat.
///
/// This protocol is the entire abstraction budget for other platforms. There is
/// no layer beneath it and none is planned.
public protocol SourceAdapter: Sendable {
    var platform: Platform { get }

    /// Whether this adapter claims the URL. Cheap, syntactic, no network.
    func canHandle(_ url: URL) -> Bool

    /// Resolves share links before intake decides whether they name a post or a collection.
    func resolvedURL(for url: URL) async throws -> URL

    /// Normalizes a URL down to its canonical ID.
    ///
    /// May hit the network — short links have to be resolved to be keyed. Must
    /// be safe to call repeatedly for the same URL.
    func canonicalID(for url: URL) async throws -> CanonicalID
}

public extension SourceAdapter {
    func resolvedURL(for url: URL) async throws -> URL { url }
}
