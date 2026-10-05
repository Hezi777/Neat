import Foundation

/// Where everything lives. All of it under `~/Neat/`.
public struct NeatPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: NeatPaths {
        NeatPaths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Neat", directoryHint: .isDirectory))
    }

    public var ledger: URL { root.appending(path: "ledger.json") }
    public var items: URL { root.appending(path: "items", directoryHint: .isDirectory) }

    public func itemFolder(_ id: CanonicalID) -> URL {
        items.appending(path: id.folderName, directoryHint: .isDirectory)
    }

    public func itemJSON(_ id: CanonicalID) -> URL { itemFolder(id).appending(path: "item.json") }
    public func transcript(_ id: CanonicalID) -> URL { itemFolder(id).appending(path: "transcript.txt") }
    public func onscreen(_ id: CanonicalID) -> URL { itemFolder(id).appending(path: "onscreen.txt") }
    public func body(_ id: CanonicalID) -> URL { itemFolder(id).appending(path: "body.txt") }
    public func resources(_ id: CanonicalID) -> URL { itemFolder(id).appending(path: "resources.json") }

    /// Originals, full resolution.
    public func media(_ id: CanonicalID) -> URL {
        itemFolder(id).appending(path: "media", directoryHint: .isDirectory)
    }

    /// The generic OCR input directory, regardless of item type. Video
    /// keyframes, slideshow slides and post images all land here with the same
    /// naming, so the onscreen stage never branches on type.
    public func frames(_ id: CanonicalID) -> URL {
        itemFolder(id).appending(path: "frames", directoryHint: .isDirectory)
    }
}
