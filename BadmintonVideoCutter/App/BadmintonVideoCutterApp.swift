import SwiftUI

@main
struct BadmintonVideoCutterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .defaultSize(width: 1200, height: 760)
    }
}
