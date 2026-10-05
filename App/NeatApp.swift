import NeatUI
import SwiftUI

@main
struct NeatApp: App {
    var body: some Scene {
        WindowGroup {
            NeatRootView()
        }
        .defaultSize(width: NeatWindow.defaultWidth, height: NeatWindow.defaultHeight)
        .windowResizability(.contentMinSize)
        // One window. Never a second one.
        .commandsRemoved()
    }
}
