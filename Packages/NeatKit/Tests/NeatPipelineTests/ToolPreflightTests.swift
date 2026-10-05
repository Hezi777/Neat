import Foundation
import Testing

@testable import NeatPipeline

@Suite("Tool preflight")
struct ToolPreflightTests {
    /// A directory with no executables in it, so "missing" is deterministic
    /// rather than a statement about this machine.
    static let emptyDir = [NSTemporaryDirectory() + "neat-preflight-empty"]

    @Test("reports every tool missing when nothing is on the search path")
    func allMissing() {
        let result = ToolPreflight(searchPaths: Self.emptyDir).check()
        #expect(!result.isSatisfied)
        #expect(Set(result.missing) == Set(ExternalTool.allCases))
    }

    @Test("the brew command names exactly the missing tools")
    func brewCommandListsMissing() {
        let result = ToolPreflight(searchPaths: Self.emptyDir).check()
        let command = result.brewCommand
        #expect(command?.hasPrefix("brew install ") == true)
        for tool in ExternalTool.allCases {
            #expect(command?.contains(tool.brewFormula) == true)
        }
    }

    @Test("a satisfied preflight offers no brew command")
    func satisfiedHasNoCommand() throws {
        // Build a directory containing stand-ins for every external tool.
        let dir = URL.temporaryDirectory.appending(path: "neat-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for tool in ExternalTool.allCases {
            let stub = dir.appending(path: tool.rawValue)
            try Data("#!/bin/sh\n".utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path())
        }

        let result = ToolPreflight(searchPaths: [dir.path()]).check()
        #expect(result.isSatisfied)
        #expect(result.missing.isEmpty)
        #expect(result.brewCommand == nil)
        #expect(result.found.count == ExternalTool.allCases.count)
    }

    @Test("search path order decides which copy wins")
    func firstMatchWins() throws {
        let first = URL.temporaryDirectory.appending(path: "neat-a-\(UUID().uuidString)")
        let second = URL.temporaryDirectory.appending(path: "neat-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stub = dir.appending(path: ExternalTool.ffmpeg.rawValue)
            try Data("#!/bin/sh\n".utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path())
        }

        let found = ToolPreflight(searchPaths: [first.path(), second.path()]).locate(.ffmpeg)
        #expect(found?.hasPrefix(first.path()) == true)
    }
}
