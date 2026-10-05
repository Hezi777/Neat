import Foundation
import NeatCore

/// One row already in the Notion database that looks like the same resource.
public struct NotionMatch: Sendable, Equatable {
    public let pageID: String
    public let title: String
    public let url: String?

    public init(pageID: String, title: String, url: String?) {
        self.pageID = pageID
        self.title = title
        self.url = url
    }
}

/// Pushes a resource into the Notion resources database.
///
/// There is no official Notion SDK for Swift, so this is raw HTTP against
/// `api.notion.com/v1`, the same shape as `AnthropicOCR`.
///
/// The property names below are the database's real ones and must match
/// exactly — Notion rejects the whole page write on an unknown property, and
/// the URL column is literally named `URL`, not `Url`.
public struct NotionClient: Sendable {
    public static let base = URL(string: "https://api.notion.com/v1")!
    /// Notion pins behaviour to this header; it is not a "latest" alias.
    public static let apiVersion = "2022-06-28"

    public enum Property {
        public static let name = "Name"
        public static let url = "URL"
        public static let status = "Status"
        public static let category = "Category"
        public static let description = "Description"
    }

    /// The only status a push ever writes. "Reading" and "Using" are moved by
    /// hand in Notion afterwards.
    public static let defaultStatus = "Saved"

    let token: String
    let databaseID: String
    let session: URLSession

    public init(token: String, databaseID: String, session: URLSession = .shared) {
        self.token = token
        self.databaseID = databaseID
        self.session = session
    }

    /// Nil when either credential is missing, so the UI can just not offer the
    /// button rather than handling a throw.
    public init?(secrets: SecretsStore = SecretsStore(), session: URLSession = .shared) {
        guard let token = secrets.value(for: .notionToken),
              let databaseID = secrets.value(for: .notionResourcesDB)
        else { return nil }
        self.init(token: token, databaseID: databaseID, session: session)
    }

    // MARK: - Operations

    /// Rows whose URL is the same resource once normalized.
    ///
    /// Notion stores whatever was originally pasted — with `www.`, with a utm
    /// tail, with a trailing slash — so the query only narrows the set with a
    /// `contains` on the scheme-less form and the real comparison is done here
    /// with the same normalizer that produced the resource id.
    public func findByURL(_ url: String) async throws -> [NotionMatch] {
        guard let needle = ResourceURL.schemeless(url) else { return [] }

        let body: [String: Any] = [
            "filter": [
                "property": Self.Property.url,
                "url": ["contains": needle],
            ],
            "page_size": 25,
        ]

        let data = try await post("databases/\(databaseID)/query", body: body)
        return Self.matches(in: data).filter { ResourceURL.sameResource($0.url, url) }
    }

    /// Creates the page and returns its id.
    public func create(_ resource: Resource) async throws -> String {
        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": Self.properties(for: resource),
        ]

        let data = try await post("pages", body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String
        else { throw StageError.fetchFailed("Notion create returned no page id") }
        return id
    }

    /// What the UI calls once the user has decided about a duplicate. Returns
    /// the new page id, or nil when nothing was written.
    public func push(_ resource: Resource, decision: DuplicateDecision) async throws -> String? {
        switch decision {
        case .add: try await create(resource)
        case .skip: nil
        case .replace:
            // Deliberately unbuilt: overwriting a row someone may have edited by
            // hand in Notion is a decision, not a default.
            throw StageError.notImplemented("replacing an existing Notion page")
        }
    }

    // MARK: - Shapes

    static func properties(for resource: Resource) -> [String: Any] {
        var properties: [String: Any] = [
            Property.name: ["title": [["text": ["content": resource.name]]]],
            Property.status: ["select": ["name": defaultStatus]],
            Property.category: [
                "multi_select": Resource.sanitizedCategories(resource.category).map { ["name": $0] },
            ],
            Property.description: [
                "rich_text": [["text": ["content": String(resource.summary.prefix(Resource.summaryLimit))]]],
            ],
        ]
        // Notion rejects an empty string for a url property; omitting the key is
        // how you say "no URL".
        if let url = resource.url, !url.isEmpty {
            properties[Property.url] = ["url": url]
        }
        return properties
    }

    static func matches(in data: Data) -> [NotionMatch] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { page in
            guard let id = page["id"] as? String else { return nil }
            let properties = page["properties"] as? [String: Any] ?? [:]
            return NotionMatch(pageID: id, title: title(in: properties), url: url(in: properties))
        }
    }

    static func title(in properties: [String: Any]) -> String {
        let field = properties[Property.name] as? [String: Any]
        let parts = field?["title"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }

    static func url(in properties: [String: Any]) -> String? {
        let field = properties[Property.url] as? [String: Any]
        return field?["url"] as? String
    }

    // MARK: - Transport

    func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw StageError.fetchFailed("no response from Notion API")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self).prefix(300)
            throw StageError.fetchFailed("Notion API \(http.statusCode): \(detail)")
        }
        return data
    }
}
