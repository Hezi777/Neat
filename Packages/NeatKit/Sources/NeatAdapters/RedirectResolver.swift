import Foundation
import NeatCore

/// Resolves a short link to the URL it points at.
///
/// Injectable so URL parsing can be tested exhaustively without a network, and
/// so a paste of a hundred links is not a hundred live requests in tests.
public protocol RedirectResolver: Sendable {
    func resolve(_ url: URL) async throws -> URL
}

/// Follows one redirect hop at a time by reading `Location`, rather than letting
/// URLSession follow the chain and download a page body we do not want.
public struct HTTPRedirectResolver: RedirectResolver {
    public let maxHops: Int
    let session: URLSession

    public init(maxHops: Int = 5, session: URLSession = .shared) {
        self.maxHops = maxHops
        self.session = session
    }

    public func resolve(_ url: URL) async throws -> URL {
        var current = url

        for _ in 0..<maxHops {
            var request = URLRequest(url: current)
            request.httpMethod = "HEAD"
            // TikTok serves a redirect only to something that looks like a browser.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent")

            let stopper = RedirectStopper()
            let (_, response) = try await session.data(for: request, delegate: stopper)

            guard let http = response as? HTTPURLResponse else { return current }

            guard (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL
            else {
                // Not a redirect: either the final URL, or URLSession already
                // resolved it and handed us the destination.
                return response.url ?? current
            }

            current = next
            if !TikTokURL.isShortLink(current) { return current }
        }

        throw AdapterError.redirectFailed("too many redirects resolving \(url.absoluteString)")
    }
}

/// Stops URLSession following redirects itself, so we can read `Location`.
final class RedirectStopper: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
