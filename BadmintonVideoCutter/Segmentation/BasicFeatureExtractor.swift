import Foundation
import AVFoundation
import CoreImage

final class BasicFeatureExtractor: FeatureExtractor {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let audioAnalyzer = AudioAnalyzer()

    struct ProgressCallbacks {
        var onAudioProgress: @MainActor (Double) -> Void
        var onVideoProgress: @MainActor (Double) -> Void
    }

    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame] {
        return try await extractFeatures(from: videoURL, progress: nil)
    }

    func extractFeatures(from videoURL: URL, progress: ProgressCallbacks?) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        let totalDuration = try await asset.load(.duration).seconds

        async let videoFrames = extractVideoFeatures(from: videoURL, totalDuration: totalDuration, progress: progress)
        async let audioFeatures = audioAnalyzer.analyzeAudio(from: videoURL) { fraction in
            Task { @MainActor in
                progress?.onAudioProgress(fraction)
            }
        }

        let video = try await videoFrames
        let audio = try await audioFeatures

        return mergeAudioIntoVideo(videoFrames: video, audioFeatures: audio)
    }

    // MARK: - Video Feature Extraction

    private func extractVideoFeatures(from videoURL: URL, totalDuration: TimeInterval, progress: ProgressCallbacks?) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)

        var frames: [FeatureFrame] = []
        var previousLuma: Double?
        var lastReportedProgress: Double = -1
        let progressReportInterval: Double = 0.02  // report every 2%

        reader.startReading()
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let luma = averageLuma(from: pixelBuffer)
            let motion = previousLuma.map { abs(luma - $0) } ?? 0
            previousLuma = luma

            frames.append(FeatureFrame(timestamp: timestamp, motionScore: min(motion * 8.0, 1.0), audioScore: 0.0))

            // Report progress based on timestamp / duration
            if totalDuration > 0 {
                let pct = min(timestamp / totalDuration, 1.0)
                if pct - lastReportedProgress >= progressReportInterval {
                    lastReportedProgress = pct
                    let p = pct
                    await MainActor.run {
                        progress?.onVideoProgress(p)
                    }
                }
            }
        }

        return bucketize(frames: frames, window: 0.20)
    }

    // MARK: - Audio Merging

    private func mergeAudioIntoVideo(videoFrames: [FeatureFrame], audioFeatures: [AudioFeature]) -> [FeatureFrame] {
        guard !audioFeatures.isEmpty else { return videoFrames }

        let audioTimestamps = audioFeatures.map(\.timestamp)
        return videoFrames.map { frame in
            let audioScore = findNearestAudioScore(
                at: frame.timestamp,
                audioFeatures: audioFeatures,
                timestamps: audioTimestamps
            )
            return FeatureFrame(
                timestamp: frame.timestamp,
                motionScore: frame.motionScore,
                audioScore: audioScore
            )
        }
    }

    private func findNearestAudioScore(at time: TimeInterval, audioFeatures: [AudioFeature], timestamps: [Double]) -> Double {
        guard !timestamps.isEmpty else { return 0 }

        var low = 0
        var high = timestamps.count - 1
        while low < high {
            let mid = (low + high) / 2
            if timestamps[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low > 0 {
            let diffLow = abs(timestamps[low] - time)
            let diffPrev = abs(timestamps[low - 1] - time)
            if diffPrev < diffLow {
                return audioFeatures[low - 1].rallyScore
            }
        }

        return audioFeatures[low].rallyScore
    }

    // MARK: - Helpers

    private func averageLuma(from pixelBuffer: CVPixelBuffer) -> Double {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0 }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter.outputImage else { return 0 }
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(output,
                         toBitmap: &bitmap,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func bucketize(frames: [FeatureFrame], window: TimeInterval) -> [FeatureFrame] {
        guard !frames.isEmpty else { return [] }
        var out: [FeatureFrame] = []
        var bucketStart = frames[0].timestamp
        var bucket: [FeatureFrame] = []

        for frame in frames {
            if frame.timestamp - bucketStart <= window {
                bucket.append(frame)
            } else {
                out.append(aggregate(bucket))
                bucketStart = frame.timestamp
                bucket = [frame]
            }
        }
        if !bucket.isEmpty { out.append(aggregate(bucket)) }
        return out
    }

    private func aggregate(_ bucket: [FeatureFrame]) -> FeatureFrame {
        let t = bucket.map(\.timestamp).reduce(0, +) / Double(bucket.count)
        let m = bucket.map(\.motionScore).reduce(0, +) / Double(bucket.count)
        let a = bucket.map(\.audioScore).reduce(0, +) / Double(bucket.count)
        return FeatureFrame(timestamp: t, motionScore: m, audioScore: a)
    }
}
