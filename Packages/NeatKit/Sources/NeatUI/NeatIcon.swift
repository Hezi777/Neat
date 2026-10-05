import SwiftUI

/// Hugeicons, stroke style, one consistent weight.
///
/// The SVGs are generated into `Resources/NeatIcons.xcassets` as template
/// images, so they tint with the environment and never need recolouring by
/// hand. Deliberately no SF Symbols anywhere — mixing the two families is what
/// makes icon weights look inconsistent.
public enum NeatIcon: String, CaseIterable, Sendable {
    case dropWell, fetching, listening, reading, done
    case alreadyHave, unavailable, skipped, invalid
    case reveal, paste, key, tools, light, dark, empty, queued

    // Brand marks for the source sidebar (simple-icons, monochrome).
    case srcTiktok, srcThreads, srcInstagram, srcYoutube, srcReddit

    public var image: Image {
        Image(rawValue, bundle: .module).renderingMode(.template)
    }
}

extension View {
    /// One optical size scale for every icon in the app.
    func iconSize(_ size: CGFloat) -> some View {
        frame(width: size, height: size)
    }
}

public struct NeatIconView: View {
    let icon: NeatIcon
    var size: CGFloat = 18

    public init(_ icon: NeatIcon, size: CGFloat = 18) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        icon.image
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
