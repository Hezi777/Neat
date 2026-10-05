import Foundation
import NeatCore

/// An external binary Neat shells out to. Resolved from `PATH`, not bundled —
/// bundling means code-signing pain we are not paying for in v1.
public enum ExternalTool: String, Sendable, CaseIterable {
    case ytDlp = "yt-dlp"
    case ffmpeg = "ffmpeg"

    public var brewFormula: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        }
    }
}

public struct PreflightResult: Sendable, Equatable {
    public var found: [ExternalTool: String]
    public var missing: [ExternalTool]

    public var isSatisfied: Bool { missing.isEmpty }

    /// The command to show in the preflight sheet.
    public var brewCommand: String? {
        guard !missing.isEmpty else { return nil }
        return "brew install " + missing.map(\.brewFormula).joined(separator: " ")
    }
}

/// Checks that the external tools exist before the app pretends it can work.
///
/// A GUI app launched from Finder inherits a minimal `PATH` that does not
/// include Homebrew, so searching `PATH` alone would report tools missing that
/// are plainly installed. We search the usual Homebrew prefixes too.
public struct ToolPreflight: Sendable {
    /// Directories to search, in order. Injectable so the check is testable
    /// without depending on what happens to be installed on the machine.
    public let searchPaths: [String]

    public init(searchPaths: [String] = ToolPreflight.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    static let extraSearchPaths = [
        "/opt/homebrew/bin",   // Apple silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
    ]

    public static var defaultSearchPaths: [String] {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        return pathDirs + extraSearchPaths
    }

    public func locate(_ tool: ExternalTool) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = dir + "/" + tool.rawValue
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func check() -> PreflightResult {
        var found: [ExternalTool: String] = [:]
        var missing: [ExternalTool] = []

        for tool in ExternalTool.allCases {
            if let path = locate(tool) {
                found[tool] = path
            } else {
                missing.append(tool)
            }
        }

        if missing.isEmpty {
            Log.pipeline.info("Preflight satisfied")
        } else {
            Log.pipeline.warning("Preflight missing: \(missing.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }

        return PreflightResult(found: found, missing: missing)
    }
}
