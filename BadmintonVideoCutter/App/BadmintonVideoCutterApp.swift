import SwiftUI

@main
struct BadmintonVideoCutterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            UndoRedoCommands(appState: appState)
        }
    }
}

/// Undo/redo for point corrections, backed by the session ledger.
struct UndoRedoCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Correction") { appState.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!appState.canUndo)
            Button("Redo Correction") { appState.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!appState.canRedo)
        }
    }
}
