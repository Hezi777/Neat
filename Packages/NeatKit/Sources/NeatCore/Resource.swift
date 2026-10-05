import Foundation

/// One re-findable thing a post recommended — a tool, library, site, repo,
/// product or course.
///
/// This is deliberately not organizing: the extract stage only records what the
/// post itself pointed at, it does not decide what the post is *about*.
public struct Resource: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Stable across re-extraction: the normalized URL lowercased, or a slug of
    /// the name when there is no URL. Merging and Notion dedupe both key on it.
    public var id: String
    public var name: String
    public var url: String?
    /// Always a subset of `Resource.categories`. Anything else is dropped.
    public var category: [String]
    /// One line, at most `summaryLimit` characters.
    public var summary: String
    public var pushedToNotion: Bool

    public init(
        id: String,
        name: String,
        url: String? = nil,
        category: [String] = [],
        summary: String = "",
        pushedToNotion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.summary = summary
        self.pushedToNotion = pushedToNotion
    }
}

extension Resource {
    /// The Notion database's multi-select options, exactly. The model is given
    /// these as an enum and anything outside the list is dropped rather than
    /// substituted — an invented category would fail the Notion write, and a
    /// guessed one would be worse than none.
    public static let categories: [String] = [
        "Claude Code",
        "UI Components",
        "Design Inspo",
        "AI Tools",
        "Dev Infrastructure",
        "SaaS/Biz",
        "Learning",
        "BI/Data",
        "Tools",
        "GitHub",
    ]

    public static let summaryLimit = 200

    static let categorySet = Set(categories)

    /// Keeps only known categories, in the canonical order, without duplicates.
    /// An empty result is left empty on purpose.
    public static func sanitizedCategories(_ raw: [String]) -> [String] {
        let wanted = Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .intersection(categorySet)
        return categories.filter(wanted.contains)
    }

    /// Builds a resource with a stable id, a clean category list and a summary
    /// inside the limit. This is the only way the extract stage makes one.
    public static func make(name: String, url: String?, category: [String], summary: String) -> Resource? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let normalized = url.flatMap(ResourceURL.normalize)
        guard let id = normalized?.lowercased() ?? slug(name) else { return nil }

        let summary = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Resource(
            id: id,
            name: name,
            url: normalized,
            category: sanitizedCategories(category),
            summary: String(summary.prefix(summaryLimit)))
    }

    /// `Claude Code` → `claude-code`. Only used when a resource has no URL, so
    /// two mentions of the same named tool still collapse to one row.
    public static func slug(_ name: String) -> String? {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out.isEmpty ? nil : out
    }
}

/// The contents of `resources.json`. Wrapped rather than a bare array so the
/// file says what version wrote it.
public struct ResourcesFile: Codable, Sendable, Equatable {
    public var v: Int
    public var resources: [Resource]

    public init(v: Int = StageVersions.extract, resources: [Resource] = []) {
        self.v = v
        self.resources = resources
    }
}

extension ResourcesFile {
    /// Re-extracting must never make the app forget what it already pushed, so
    /// a fresh resource inherits `pushedToNotion` from the one it replaces, and
    /// an already-pushed resource the model no longer returns is kept rather
    /// than dropped — its Notion row still exists.
    ///
    /// Anything else that vanished from the fresh result is dropped: the model
    /// saw the same post and no longer thinks it is there.
    public static func merge(existing: [Resource], fresh: [Resource]) -> [Resource] {
        let pushed = existing.filter(\.pushedToNotion)
        let pushedIDs = Set(pushed.map(\.id))

        var seen = Set<String>()
        var out: [Resource] = []
        for var resource in fresh {
            guard seen.insert(resource.id).inserted else { continue }
            if pushedIDs.contains(resource.id) { resource.pushedToNotion = true }
            out.append(resource)
        }
        out.append(contentsOf: pushed.filter { !seen.contains($0.id) })
        return out
    }
}

/// What to do about a resource whose URL is already in the Notion database.
/// The UI decides; the pipeline only reports the matches.
public enum DuplicateDecision: String, Codable, Sendable, CaseIterable {
    case add
    case skip
    /// Not implemented — updating an existing Notion page is a later decision.
    case replace
}
