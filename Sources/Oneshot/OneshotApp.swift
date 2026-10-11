import SwiftUI

/// Menu bar only app (LSUIElement). Everything is driven from the status item in AppDelegate.
@main
struct OneshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
