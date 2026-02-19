import SwiftUI
import AVKit

/// NSViewRepresentable wrapper for AVPlayerView, avoiding the _AVKit_SwiftUI VideoPlayer crash
/// on macOS 26 beta where Swift metadata initialization fails.
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct VideoPlayerPane: View {
    let assetURL: URL?

    var body: some View {
        Group {
            if let url = assetURL {
                NativePlayerView(player: AVPlayer(url: url))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.gray.opacity(0.15))
                    .overlay(Text("No video loaded").foregroundStyle(.secondary))
                    .frame(minHeight: 280)
            }
        }
    }
}
