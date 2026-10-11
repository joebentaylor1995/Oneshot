import SwiftUI

/// Menu bar only app (LSUIElement). Everything is driven from the status item in AppDelegate.
@main
struct ReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
