import Foundation
import AVFoundation
import CoreImage

final class BasicFeatureExtractor: FeatureExtractor {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let audioAnalyzer = AudioAnalyzer()

    /// Resolution for motion analysis. 320x180 gives good accuracy at reasonable cost.
    private let analysisWidth = 320
    private let analysisHeight = 180

    struct ProgressCallbacks {
        var onAudioProgress: @MainActor (Double) -> Void
        var onVideoProgress: @MainActor (Double) -> Void
    }

    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame] {
        return try await extractFeatures(from: videoURL, mlModelURL: nil, progress: nil)
    }

    func extractFeatures(from videoURL: URL, mlModelURL: URL? = nil, progress: ProgressCallbacks?) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        let totalDuration = try await asset.load(.duration).seconds

        async let videoFrames = extractVideoFeatures(from: videoURL, totalDuration: totalDuration, progress: progress)
        async let audioFeatures = audioAnalyzer.analyzeAudio(from: videoURL, mlModelURL: mlModelURL) { fraction in
            Task { @MainActor in
                progress?.onAudioProgress(fraction)
            }
        }

        let video = try await videoFrames
        let audio = try await audioFeatures

        return mergeAudioIntoVideo(videoFrames: video, audioFeatures: audio)
    }

    // MARK: - Video Feature Extraction (Per-Pixel Frame Differencing)

    private func extractVideoFeatures(from videoURL: URL, totalDuration: TimeInterval, progress: ProgressCallbacks?) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // Process every ~200ms for meaningful motion between frames
        let frameSkip = max(1, Int(frameRate * 0.2))

        let pixelCount = analysisWidth * analysisHeight
        var frames: [FeatureFrame] = []
        var previousGray: [UInt8]?
        var frameIndex = 0
        var lastReportedProgress: Double = -1
        let progressReportInterval: Double = 0.02

        reader.startReading()
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frameIndex += 1
            guard frameIndex % frameSkip == 0 else { continue }

            // Render to grayscale at analysis resolution
            guard let currentGray = renderToGrayscale(pixelBuffer) else {
                frames.append(FeatureFrame(timestamp: timestamp, motionScore: 0, audioScore: 0))
                continue
            }

            let motion: Double
            if let prev = previousGray {
                motion = computeMotionScore(prev, currentGray, pixelCount: pixelCount)
            } else {
                motion = 0
            }
            previousGray = currentGray

            frames.append(FeatureFrame(timestamp: timestamp, motionScore: motion, audioScore: 0.0))

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

        return frames
    }

    // MARK: - Motion Detection (Per-Pixel Frame Differencing)

    /// Compute motion score by comparing grayscale pixel values between frames.
    /// Focuses on lower 80% of frame (where players are), applies noise threshold,
    /// and uses a two-tier scoring: fraction of pixels that moved + average movement intensity.
    private func computeMotionScore(_ prev: [UInt8], _ curr: [UInt8], pixelCount: Int) -> Double {
        let width = analysisWidth
        let height = analysisHeight

        // Skip top 20% (ceiling/lights in indoor courts)
        let startRow = height / 5
        let noiseThreshold: Int = 12  // Ignore differences below this (sensor noise, compression)

        var movingPixels = 0
        var totalDiff: Int = 0
        var regionPixels = 0

        for y in startRow..<height {
            let rowOffset = y * width
            for x in 0..<width {
                let idx = rowOffset + x
                let diff = abs(Int(curr[idx]) - Int(prev[idx]))
                regionPixels += 1
                if diff > noiseThreshold {
                    movingPixels += 1
                    totalDiff += diff
                }
            }
        }

        guard regionPixels > 0, movingPixels > 0 else { return 0 }

        // Fraction of pixels with significant motion
        let motionFraction = Double(movingPixels) / Double(regionPixels)

        // Average intensity of the moving pixels (normalized to 0-1, max diff = 255)
        let avgIntensity = Double(totalDiff) / Double(movingPixels) / 255.0

        // Combined score: weighted blend of coverage and intensity
        // During rallies: ~5-20% of pixels move with moderate intensity
        // Between points: <2% move (people standing still)
        let score = motionFraction * 0.6 + avgIntensity * 0.4

        // Scale so typical rally motion (~10% moving pixels, ~0.15 avg intensity)
        // maps to ~0.4-0.6 range
        return min(score * 4.0, 1.0)
    }

    // MARK: - Frame Rendering

    /// Render a pixel buffer to a grayscale byte array at analysis resolution.
    /// Uses CIImage pipeline for fast, GPU-accelerated scaling.
    private func renderToGrayscale(_ source: CVPixelBuffer) -> [UInt8]? {
        // Scale to analysis resolution
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = CGFloat(analysisWidth) / ciImage.extent.width
        let scaleY = CGFloat(analysisHeight) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        // Render to RGBA then convert to grayscale
        let width = analysisWidth
        let height = analysisHeight
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to grayscale using luminance weights
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4])
            let g = Int(rgba[i * 4 + 1])
            let b = Int(rgba[i * 4 + 2])
            // ITU-R BT.601 luminance
            gray[i] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
        }

        return gray
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
}
