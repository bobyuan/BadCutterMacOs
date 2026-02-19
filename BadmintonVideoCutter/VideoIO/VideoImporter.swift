import Foundation
import AVFoundation

final class VideoImporter {
    func loadAsset(url: URL) -> AVAsset {
        AVURLAsset(url: url)
    }
}
