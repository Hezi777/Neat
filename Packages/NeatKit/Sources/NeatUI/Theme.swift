import SwiftUI

/// Window metrics, stated once and shared with the app shell.
public enum NeatWindow {
    public static let minWidth: CGFloat = 980
    public static let minHeight: CGFloat = 520
    public static let defaultWidth: CGFloat = 1040
    public static let defaultHeight: CGFloat = 660
    public static let sidebarMin: CGFloat = 180
    public static let sidebarIdeal: CGFloat = 210
}

/// The spacing scale. Every gap in the app comes from here — the M5 pass checks
/// that from a screenshot, and one scale is what makes that check passable.
public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 20
    public static let xl: CGFloat = 32
}

/// One icon size scale, so every glyph shares an optical size.
public enum IconSize {
    public static let row: CGFloat = 17
    public static let sidebar: CGFloat = 16
    public static let control: CGFloat = 15
    public static let hero: CGFloat = 30
}

public enum Radius {
    public static let row: CGFloat = 12
    public static let well: CGFloat = 18
}

/// Light by default, with an explicit dark option.
public enum Appearance: String, CaseIterable, Sendable {
    case light, dark

    public var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    public var toggleIcon: NeatIcon {
        switch self {
        case .light: .dark   // offers the other one
        case .dark: .light
        }
    }

    public var toggleHelp: String {
        switch self {
        case .light: "Switch to dark"
        case .dark: "Switch to light"
        }
    }

    public var next: Appearance {
        switch self {
        case .light: .dark
        case .dark: .light
        }
    }
}

/// One accent plus neutrals, matching the app icon's navy-to-purple.
///
/// Stated explicitly rather than read from `.accentColor`.
///
/// The app does ship an `AccentColor` asset, but macOS only honours it when the
/// user's System Settings accent is "Multicolor" — a fixed system accent wins,
/// which left the icons purple and every control blue. Applying this as an
/// explicit `.tint` keeps one accent whatever the system is set to.
public extension Color {
    static let neatAccent = Color(.displayP3, red: 0.40, green: 0.28, blue: 0.92)
}
