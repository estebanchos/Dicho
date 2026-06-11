import SwiftUI

@main
struct DichoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Placeholder Settings scene; populated in M6.
        // Required so SwiftUI has at least one scene to manage.
        Settings {
            EmptyView()
        }
    }
}
