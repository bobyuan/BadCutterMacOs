import SwiftUI
import AVKit

struct VideoPlayerPane: View {
    let assetURL: URL?

    var body: some View {
        Group {
            if let url = assetURL {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.gray.opacity(0.15))
                    .overlay(Text("No video loaded").foregroundStyle(.secondary))
                    .frame(minHeight: 280)
            }
        }
    }
}
