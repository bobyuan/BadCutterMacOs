import SwiftUI

/// Root view: hosts the single-window "Studio" layout
/// (Library | Player + Timeline | Inspector).
struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        StudioView(appState: appState)
    }
}
