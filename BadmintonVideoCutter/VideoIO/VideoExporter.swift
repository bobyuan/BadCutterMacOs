import Foundation
import AVFoundation

/// One file to render: a reel (many segments) or an individual clip (one).
struct ExportJob {
    var label: String
    var outputURL: URL
    var segments: [TimeSegment]
}

final class VideoExporter {

    /// Render each job to disk sequentially. `matchSourceFormat` tries a
    /// passthrough export (keeps the source codec, cuts land on keyframes);
    /// it falls back to a highest-quality re-encode when passthrough fails.
    func run(
        jobs: [ExportJob],
        assetURL: URL,
        matchSourceFormat: Bool,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> [ExportOutput] {
        var outputs: [ExportOutput] = []
        for (index, job) in jobs.enumerated() {
            await onProgress("Exporting \(job.label) (\(index + 1)/\(jobs.count))…")
            let url = try await export(
                segments: job.segments,
                assetURL: assetURL,
                outputURL: job.outputURL,
                matchSourceFormat: matchSourceFormat
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let duration = job.segments.reduce(0) { $0 + $1.duration }
            outputs.append(ExportOutput(label: job.label, url: url, duration: duration, fileSize: size ?? 0))
        }
        return outputs
    }

    private func export(
        segments: [TimeSegment],
        assetURL: URL,
        outputURL: URL,
        matchSourceFormat: Bool
    ) async throws -> URL {
        let valid = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !valid.isEmpty else {
            throw NSError(domain: "VideoExporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "Nothing selected to export."])
        }

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

        var cursor = CMTime.zero
        for s in valid {
            let range = CMTimeRange(
                start: CMTime(seconds: s.start, preferredTimescale: 600),
                end: CMTime(seconds: s.end, preferredTimescale: 600)
            )
            try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack, let compAudio {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            cursor = cursor + range.duration
        }

        if matchSourceFormat {
            do {
                return try await runSession(composition: composition, preset: AVAssetExportPresetPassthrough, outputURL: outputURL)
            } catch {
                // Passthrough is codec-dependent — fall through to re-encode.
            }
        }
        return try await runSession(composition: composition, preset: AVAssetExportPresetHighestQuality, outputURL: outputURL)
    }

    private func runSession(composition: AVMutableComposition, preset: String, outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "VideoExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        session.outputURL = outputURL
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
        return outputURL
    }
}
