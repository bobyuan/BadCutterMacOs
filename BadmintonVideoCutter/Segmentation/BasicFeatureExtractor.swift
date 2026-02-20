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

    // MARK: - Video Feature Extraction (Shuttlecock-Aware Motion Detection)

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

        var frames: [FeatureFrame] = []
        var previousRGBA: [UInt8]?
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

            // Render to RGBA at analysis resolution (need color channels for white detection)
            guard let currentRGBA = renderToRGBA(pixelBuffer) else {
                frames.append(FeatureFrame(timestamp: timestamp, motionScore: 0, audioScore: 0))
                continue
            }

            let motion: Double
            if let prev = previousRGBA {
                motion = computeMotionScore(prev, currentRGBA, timestamp: timestamp)
            } else {
                motion = 0
            }
            previousRGBA = currentRGBA

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

    // MARK: - Motion Detection (Shuttlecock White-Motion + General Motion)

    /// Raw diagnostic data from the last extraction run.
    /// Only populated when `collectDiagnostics` is true.
    struct MotionDiagnostics {
        var timestamp: TimeInterval
        var displacedWhiteCount: Int
        var generalMotionScore: Double
        var blendedScore: Double
    }
    var collectDiagnostics = false
    private(set) var diagnostics: [MotionDiagnostics] = []

    /// Compute blended motion score combining shuttlecock-specific white-pixel displacement
    /// with general frame differencing.
    ///
    /// The shuttlecock is a small, bright white object that moves rapidly during rallies.
    /// By tracking "displaced white pixels" (white at position (x,y) in one frame but not
    /// the other), we get a direct signal for shuttlecock movement. Static white elements
    /// like court lines contribute zero since they stay in the same position.
    private func computeMotionScore(_ prevRGBA: [UInt8], _ currRGBA: [UInt8], timestamp: TimeInterval = 0) -> Double {
        let width = analysisWidth
        let height = analysisHeight

        // Skip top 20% (ceiling/lights in indoor courts)
        let startRow = height / 5
        let noiseThreshold: Int = 12
        let luminanceThreshold: Int = 200  // Bright pixels (shuttlecock is very bright)
        let saturationThreshold: Int = 50  // Low saturation = white/gray, not colored

        var displacedWhiteCount = 0
        var movingPixels = 0
        var totalDiff: Int = 0
        var regionPixels = 0

        for y in startRow..<height {
            let rowOffset = y * width
            for x in 0..<width {
                let idx = rowOffset + x
                let rgbaIdx = idx * 4

                // Current pixel RGB
                let cR = Int(currRGBA[rgbaIdx])
                let cG = Int(currRGBA[rgbaIdx + 1])
                let cB = Int(currRGBA[rgbaIdx + 2])

                // Previous pixel RGB
                let pR = Int(prevRGBA[rgbaIdx])
                let pG = Int(prevRGBA[rgbaIdx + 1])
                let pB = Int(prevRGBA[rgbaIdx + 2])

                // Luminance (ITU-R BT.601)
                let currLum = (cR * 77 + cG * 150 + cB * 29) >> 8
                let prevLum = (pR * 77 + pG * 150 + pB * 29) >> 8

                // White detection: high luminance + low saturation
                let currMaxCh = max(cR, max(cG, cB))
                let currMinCh = min(cR, min(cG, cB))
                let currIsWhite = currLum > luminanceThreshold && (currMaxCh - currMinCh) < saturationThreshold

                let prevMaxCh = max(pR, max(pG, pB))
                let prevMinCh = min(pR, min(pG, pB))
                let prevIsWhite = prevLum > luminanceThreshold && (prevMaxCh - prevMinCh) < saturationThreshold

                // Displaced white: white in one frame but not the other at same position
                // This captures shuttlecock arriving at or departing from this pixel
                if currIsWhite != prevIsWhite {
                    displacedWhiteCount += 1
                }

                // General motion (luminance-based frame differencing)
                regionPixels += 1
                let lumDiff = abs(currLum - prevLum)
                if lumDiff > noiseThreshold {
                    movingPixels += 1
                    totalDiff += lumDiff
                }
            }
        }

        // White-motion score: displaced white pixels correlate with activity level.
        // Median count is ~18, p90 is ~41 at 320x180. Use sqrt to compress outliers
        // while preserving sensitivity at lower counts.
        let shuttlecockScore = min(sqrt(Double(displacedWhiteCount)) / 7.0, 1.0)

        // General motion score (same approach as before)
        let generalMotionScore: Double
        if regionPixels > 0, movingPixels > 0 {
            let motionFraction = Double(movingPixels) / Double(regionPixels)
            let avgIntensity = Double(totalDiff) / Double(movingPixels) / 255.0
            let raw = motionFraction * 0.6 + avgIntensity * 0.4
            generalMotionScore = min(raw * 4.0, 1.0)
        } else {
            generalMotionScore = 0
        }

        // Multiplicative boost: white-motion amplifies general motion rather than raising the floor.
        // This preserves the dynamic range for low-activity periods (breaks, between-points)
        // while giving a modest boost to high-activity frames with shuttlecock/player movement.
        let blended = min(generalMotionScore * (1.0 + 0.3 * shuttlecockScore), 1.0)

        if collectDiagnostics {
            diagnostics.append(MotionDiagnostics(
                timestamp: timestamp,
                displacedWhiteCount: displacedWhiteCount,
                generalMotionScore: generalMotionScore,
                blendedScore: blended
            ))
        }

        return blended
    }

    // MARK: - Frame Rendering

    /// Render a pixel buffer to an RGBA byte array at analysis resolution.
    /// Uses CIImage pipeline for fast, GPU-accelerated scaling.
    private func renderToRGBA(_ source: CVPixelBuffer) -> [UInt8]? {
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = CGFloat(analysisWidth) / ciImage.extent.width
        let scaleY = CGFloat(analysisHeight) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

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

        return rgba
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
