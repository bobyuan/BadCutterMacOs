import Foundation
import AVFoundation

final class VideoExporter {
    func exportRallyOnly(assetURL: URL, segments: [TimeSegment]) async throws -> URL {
        let asset = AVURLAsset(url: assetURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }
        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let rallySegments = segments
            .filter { $0.label == .rally && $0.end > $0.start }
            .sorted { $0.start < $1.start }

        guard !rallySegments.isEmpty else {
            throw NSError(domain: "VideoExporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "No rally segments detected. Try Analyze again with a more aggressive sensitivity."])
        }

        var cursor = CMTime.zero
        for s in rallySegments {
            let start = CMTime(seconds: s.start, preferredTimescale: 600)
            let end = CMTime(seconds: s.end, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack, let compAudio {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            cursor = cursor + range.duration
        }

        let outURL = assetURL.deletingPathExtension().appendingPathExtension("rallies.mov")
        try? FileManager.default.removeItem(at: outURL)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        session.outputURL = outURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed: continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: session.error ?? NSError(domain: "VideoExporter", code: 4))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "VideoExporter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
                default:
                    continuation.resume(throwing: NSError(domain: "VideoExporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Export ended in unexpected state"]))
                }
            }
        }

        return outURL
    }
}
