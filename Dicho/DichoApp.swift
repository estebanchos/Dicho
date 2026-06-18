import SwiftUI

@main
struct DichoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene is managed by SettingsWindowController in AppDelegate.
        // A placeholder scene is required so SwiftUI has at least one scene to manage.
        Settings {
            EmptyView()
        }
    }
}
