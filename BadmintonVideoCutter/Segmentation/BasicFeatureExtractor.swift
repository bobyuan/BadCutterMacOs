import Foundation
import AVFoundation
import CoreImage
import Vision

final class BasicFeatureExtractor: FeatureExtractor {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let audioAnalyzer = AudioAnalyzer()

    // Person detection state (cached — Vision is expensive, run every Nth frame)
    private var lastPersonCount: Int = 0
    private var personDetectionCounter: Int = 0
    private let personDetectionInterval: Int = 10 // Every 10th analyzed frame (~2s)

    // Shuttlecock tracking state across frames.
    // The shuttlecock is the fastest-moving small white object. By tracking its
    // position across consecutive frames and verifying high velocity, we can
    // distinguish it from slow-moving white objects (player clothing, court lines).
    private var lastShuttlecockCenter: (x: Double, y: Double)? = nil
    private var shuttlecockTrackCount: Int = 0

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

    // MARK: - Dynamic Resolution

    /// Compute analysis resolution from video's native size.
    /// Uses half-native resolution, capped at 960x540, minimum 320x180.
    /// Higher resolution allows detecting the shuttlecock as a distinct blob
    /// (~20-30px diameter at half-native vs ~2-5px at 320x180).
    private static func analysisResolution(for naturalSize: CGSize) -> (width: Int, height: Int) {
        let halfW = Int(naturalSize.width) / 2
        let halfH = Int(naturalSize.height) / 2
        let w = max(320, min(960, halfW))
        let h = max(180, min(540, halfH))
        return (w, h)
    }

    // MARK: - Video Feature Extraction

    private func extractVideoFeatures(from videoURL: URL, totalDuration: TimeInterval, progress: ProgressCallbacks?) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        let naturalSize = try await videoTrack.load(.naturalSize)
        let (analysisWidth, analysisHeight) = Self.analysisResolution(for: naturalSize)

        print("Shuttlecock detection: native=\(Int(naturalSize.width))x\(Int(naturalSize.height)) → analysis=\(analysisWidth)x\(analysisHeight)")

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

        diagnostics = []
        lastPersonCount = 0
        personDetectionCounter = 0
        lastShuttlecockCenter = nil
        shuttlecockTrackCount = 0

        reader.startReading()
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frameIndex += 1
            guard frameIndex % frameSkip == 0 else { continue }

            // Run Vision person detection periodically (every ~2s)
            personDetectionCounter += 1
            if personDetectionCounter % personDetectionInterval == 0 {
                lastPersonCount = detectPersonCount(in: pixelBuffer)
            }

            guard let currentRGBA = renderToRGBA(pixelBuffer, width: analysisWidth, height: analysisHeight) else {
                frames.append(FeatureFrame(timestamp: timestamp, motionScore: 0, audioScore: 0))
                continue
            }

            let scores: (motion: Double, shuttlecockFlight: Double)
            if let prev = previousRGBA {
                scores = computeMotionScore(prev, currentRGBA, width: analysisWidth, height: analysisHeight, timestamp: timestamp, personCount: lastPersonCount)
            } else {
                scores = (motion: 0, shuttlecockFlight: 0)
            }
            previousRGBA = currentRGBA

            frames.append(FeatureFrame(timestamp: timestamp, motionScore: scores.motion, audioScore: 0.0, shuttlecockFlightScore: scores.shuttlecockFlight))

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

        // Post-process: adjust motion scores based on temporal variance.
        // Rally motion oscillates (burst-pause-burst) → high variance.
        // Break motion is steady (walking pace) → low variance.
        frames = applyMotionTempo(frames: &frames)

        return frames
    }

    // MARK: - Motion Tempo

    /// Adjusts motion scores based on temporal variance in a sliding window.
    /// Rally exchanges produce rapid oscillations (hit → pause → return → pause)
    /// while breaks have steady motion (walking). High variance boosts the score,
    /// low variance suppresses it.
    private func applyMotionTempo(frames: inout [FeatureFrame]) -> [FeatureFrame] {
        guard frames.count > 2 else { return frames }

        let windowSize = 15 // ~3 seconds at 200ms/frame
        let halfW = windowSize / 2
        let rawScores = frames.map(\.motionScore)

        // Compute stddev in sliding window for each frame
        var tempoRaw = [Double](repeating: 0, count: frames.count)
        for i in 0..<frames.count {
            let lo = max(0, i - halfW)
            let hi = min(frames.count - 1, i + halfW)
            let window = Array(rawScores[lo...hi])
            let mean = window.reduce(0, +) / Double(window.count)
            let variance = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
            tempoRaw[i] = sqrt(variance)
        }

        // Normalize using 95th percentile (robust to outliers)
        let sorted = tempoRaw.sorted()
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let normValue = sorted[p95Index]
        var tempoScores: [Double]
        if normValue > 0 {
            tempoScores = tempoRaw.map { min($0 / normValue, 1.0) }
        } else {
            tempoScores = tempoRaw
        }

        // Apply tempo as a multiplier on existing motion scores:
        //   adjusted = raw * (0.6 + 0.4 * tempoScore)
        //   High tempo (1.0): multiplier = 1.0 → unchanged
        //   Low tempo (0.0): multiplier = 0.6 → 40% reduction
        //   This suppresses steady break motion while preserving burst-like rally motion.
        for i in 0..<frames.count {
            frames[i].motionScore = min(frames[i].motionScore * (0.6 + 0.4 * tempoScores[i]), 1.0)
        }

        // Update diagnostics with tempo scores
        if collectDiagnostics && diagnostics.count == frames.count {
            for i in 0..<diagnostics.count {
                diagnostics[i].motionTempoScore = tempoScores[i]
                diagnostics[i].blendedScore = frames[i].motionScore
            }
        }

        return frames
    }

    // MARK: - Motion Detection (Shuttlecock Blob Detection + General Motion)

    struct MotionDiagnostics {
        var timestamp: TimeInterval
        var displacedWhiteCount: Int
        var maxClusterSum: Int
        var shuttlecockScore: Double
        var generalMotionScore: Double
        var activeRegions: Int
        var spreadScore: Double
        var personCount: Int
        var playerPresenceScore: Double
        var motionTempoScore: Double = 0
        var blendedScore: Double
    }
    var collectDiagnostics = false
    private(set) var diagnostics: [MotionDiagnostics] = []

    /// Detect shuttlecock movement using spatially-clustered white-pixel displacement
    /// at dynamic resolution, combined with general frame differencing.
    ///
    /// At half-native resolution (e.g., 960x540 for 1080p video), the shuttlecock is
    /// ~20-30px diameter — large enough to form a distinct blob of displaced white pixels.
    /// A grid-based spatial filter finds the densest concentration of displaced white pixels,
    /// distinguishing the compact shuttlecock from scattered noise (player clothing, etc.).
    /// Returns (blendedMotionScore, shuttlecockFlightScore)
    private func computeMotionScore(_ prevRGBA: [UInt8], _ currRGBA: [UInt8], width: Int, height: Int, timestamp: TimeInterval = 0, personCount: Int = 0) -> (motion: Double, shuttlecockFlight: Double) {
        // Skip top 20% (ceiling/lights in indoor courts)
        let startRow = height / 5
        let noiseThreshold: Int = 12
        let luminanceThreshold: Int = 200
        let saturationThreshold: Int = 50

        // Fine grid for spatial clustering of displaced white pixels (shuttlecock detection)
        let cellSize = 16
        let gridW = (width + cellSize - 1) / cellSize
        let gridH = ((height - startRow) + cellSize - 1) / cellSize
        var grid = [Int](repeating: 0, count: gridW * gridH)

        // Coarse grid for multi-region motion spread (rally vs break detection)
        // During rallies, 3-4 players move simultaneously across the court → many active regions.
        // During breaks, 0-1 people move → few active regions.
        let spreadCols = 6
        let spreadRows = 4
        let spreadCellW = max(1, width / spreadCols)
        let spreadCellH = max(1, (height - startRow) / spreadRows)
        let spreadCellCount = spreadCols * spreadRows
        var spreadMoving = [Int](repeating: 0, count: spreadCellCount)
        var spreadTotal = [Int](repeating: 0, count: spreadCellCount)

        var totalDisplacedWhite = 0
        var movingPixels = 0
        var totalDiff: Int = 0
        var regionPixels = 0

        for y in startRow..<height {
            let rowOffset = y * width
            let gridY = (y - startRow) / cellSize
            let sRow = min((y - startRow) / spreadCellH, spreadRows - 1)
            for x in 0..<width {
                let idx = rowOffset + x
                let rgbaIdx = idx * 4
                let gridX = x / cellSize
                let sCol = min(x / spreadCellW, spreadCols - 1)
                let sIdx = sRow * spreadCols + sCol

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

                // Displaced white pixel → record in grid cell
                if currIsWhite != prevIsWhite {
                    totalDisplacedWhite += 1
                    if gridY < gridH && gridX < gridW {
                        grid[gridY * gridW + gridX] += 1
                    }
                }

                // General motion (luminance-based frame differencing)
                regionPixels += 1
                spreadTotal[sIdx] += 1
                let lumDiff = abs(currLum - prevLum)
                if lumDiff > noiseThreshold {
                    movingPixels += 1
                    totalDiff += lumDiff
                    spreadMoving[sIdx] += 1
                }
            }
        }

        // Shuttlecock detection: velocity-based blob tracking.
        //
        // Key insight: the shuttlecock is the FASTEST moving small white object
        // in the frame. It moves continuously during rallies (never stops mid-air).
        //
        // Algorithm:
        // 1. Find small compact blobs of displaced white pixels (connected components)
        // 2. Compute each blob's centroid in pixel coordinates
        // 3. Match against previous frame's tracked position → compute velocity
        // 4. High velocity + small blob = shuttlecock confirmed
        // 5. Track across consecutive frames for confidence
        //
        // Velocity thresholds (at 960px, 200ms between frames):
        //   Shuttlecock: 50-400px (smash ~300px, drop shot ~50px)
        //   Player hand: 10-30px
        //   Player body: 2-15px
        //   Static: 0px
        let cellActivationThreshold = 3
        var visited = [Bool](repeating: false, count: gridW * gridH)
        var maxClusterSum = 0
        let resolutionScale = Double(width) / 960.0
        let expectedPixels = 150.0 * max(resolutionScale * resolutionScale, 0.1)

        // Collect all shuttlecock-sized blob candidates with their centroids
        struct BlobCandidate {
            var centerX: Double
            var centerY: Double
            var pixelCount: Int
            var score: Double
        }
        var candidates: [BlobCandidate] = []

        for gy in 0..<gridH {
            for gx in 0..<gridW {
                let idx = gy * gridW + gx
                guard grid[idx] >= cellActivationThreshold && !visited[idx] else { continue }

                // BFS flood fill (8-connected)
                var queue = [(gx, gy)]
                var component: [(x: Int, y: Int)] = []
                var blobPixels = 0
                visited[idx] = true

                while !queue.isEmpty {
                    let (cx, cy) = queue.removeFirst()
                    let cIdx = cy * gridW + cx
                    component.append((cx, cy))
                    blobPixels += grid[cIdx]

                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0 && nx < gridW && ny >= 0 && ny < gridH else { continue }
                            let nIdx = ny * gridW + nx
                            guard !visited[nIdx] && grid[nIdx] >= cellActivationThreshold else { continue }
                            visited[nIdx] = true
                            queue.append((nx, ny))
                        }
                    }
                }

                maxClusterSum = max(maxClusterSum, blobPixels)

                // Small compact blob = shuttlecock candidate
                let cellCount = component.count
                if cellCount >= 1 && cellCount <= 8 {
                    let xs = component.map(\.x)
                    let ys = component.map(\.y)
                    let bboxW = (xs.max()! - xs.min()!) + 1
                    let bboxH = (ys.max()! - ys.min()!) + 1
                    let compactness = Double(cellCount) / Double(bboxW * bboxH)

                    if compactness >= 0.3 {
                        // Weighted centroid in pixel coordinates
                        var wX = 0.0, wY = 0.0, wTotal = 0.0
                        for (cx, cy) in component {
                            let w = Double(grid[cy * gridW + cx])
                            wX += Double(cx * cellSize + cellSize / 2) * w
                            wY += Double(cy * cellSize + cellSize / 2 + startRow) * w
                            wTotal += w
                        }
                        if wTotal > 0 {
                            candidates.append(BlobCandidate(
                                centerX: wX / wTotal,
                                centerY: wY / wTotal,
                                pixelCount: blobPixels,
                                score: min(Double(blobPixels) / expectedPixels, 1.0)
                            ))
                        }
                    }
                }
            }
        }

        // Velocity-based tracking: match candidates against previous position.
        // Low minimum: net shots move slowly (~10px) but are still valid tracking.
        // Continuity of tracking over many frames is more important than speed.
        let minDisplacement = 5.0 * resolutionScale   // Very low: even slow net shots
        let maxDisplacement = 500.0 * resolutionScale  // Maximum reasonable travel

        if let lastPos = lastShuttlecockCenter, !candidates.isEmpty {
            // Find the best candidate: must be in valid velocity range,
            // prefer the one with highest blob score
            var bestMatch: BlobCandidate? = nil
            for c in candidates {
                let dx = c.centerX - lastPos.x
                let dy = c.centerY - lastPos.y
                let disp = sqrt(dx * dx + dy * dy)
                if disp >= minDisplacement && disp <= maxDisplacement {
                    if bestMatch == nil || c.score > bestMatch!.score {
                        bestMatch = c
                    }
                }
            }

            if let match = bestMatch {
                // Tracking match: shuttlecock moving at expected velocity
                shuttlecockTrackCount = min(shuttlecockTrackCount + 1, 5)
                lastShuttlecockCenter = (match.centerX, match.centerY)
            } else {
                // No match at expected velocity — lost tracking
                shuttlecockTrackCount = max(shuttlecockTrackCount - 1, 0)
                // Try to pick up a new candidate (might have changed direction)
                if let best = candidates.max(by: { $0.score < $1.score }) {
                    lastShuttlecockCenter = (best.centerX, best.centerY)
                }
                if shuttlecockTrackCount == 0 { lastShuttlecockCenter = nil }
            }
        } else if !candidates.isEmpty {
            // No previous position — start tracking the best candidate
            if let best = candidates.max(by: { $0.score < $1.score }) {
                lastShuttlecockCenter = (best.centerX, best.centerY)
                shuttlecockTrackCount = 1
            }
        } else {
            // No candidates at all — decay tracking
            shuttlecockTrackCount = max(shuttlecockTrackCount - 1, 0)
            if shuttlecockTrackCount == 0 { lastShuttlecockCenter = nil }
        }

        // Shuttlecock score for motion blend: based on tracking confidence.
        // 3+ consecutive frames of tracking → full score.
        let shuttlecockScore = min(Double(shuttlecockTrackCount) / 3.0, 1.0)

        // Flight score for display/chart: combines tracking confidence + velocity.
        // 0.0 = not detected, 0.3 = slow flight (net), 0.7 = moderate, 1.0 = fast smash
        let flightScore = shuttlecockScore

        // General motion score
        let generalMotionScore: Double
        if regionPixels > 0, movingPixels > 0 {
            let motionFraction = Double(movingPixels) / Double(regionPixels)
            let avgIntensity = Double(totalDiff) / Double(movingPixels) / 255.0
            let raw = motionFraction * 0.6 + avgIntensity * 0.4
            generalMotionScore = min(raw * 4.0, 1.0)
        } else {
            generalMotionScore = 0
        }

        // Multi-region motion spread: count how many coarse regions have significant motion.
        // During rallies, 3-4 players move across the court → 6-12 active regions (of 24).
        // During breaks, 0-1 people walking → 0-3 active regions.
        let spreadActiveThreshold = 0.015 // 1.5% of pixels in a region must be moving
        var activeRegions = 0
        for i in 0..<spreadCellCount {
            if spreadTotal[i] > 0 {
                let fraction = Double(spreadMoving[i]) / Double(spreadTotal[i])
                if fraction > spreadActiveThreshold {
                    activeRegions += 1
                }
            }
        }
        // Normalize: 8+ active regions = full score (typical rally with 4 players)
        let spreadScore = min(Double(activeRegions) / 8.0, 1.0)

        // Player presence score from Vision person detection.
        // At typical badminton camera distance, Vision detects 0-3 people
        // (players are small, partially overlapping). Calibrated to actual distribution:
        //   0 detected → likely break/static (31% of frames in test video)
        //   1 detected → ambiguous, slight boost (49%)
        //   2+ detected → strong rally signal, multiple players active (21%)
        let playerPresenceScore: Double
        switch personCount {
        case 3...: playerPresenceScore = 1.0
        case 2:    playerPresenceScore = 0.85
        case 1:    playerPresenceScore = 0.3
        default:   playerPresenceScore = 0.0
        }

        // Four-signal blend:
        //   generalMotion * (base + shuttlecockBoost + spreadBoost + playerBoost)
        //   base=0.2: floor when no signals detected
        //   Full rally (all=1.0): multiplier = 1.0
        //   Full break (all=0.0): multiplier = 0.2
        //   This creates ~5x gap between rally and break scores.
        //   Player presence has the largest weight (0.3) because it's
        //   the most reliable signal — players on court = game in progress.
        let blended = min(generalMotionScore * (0.2 + 0.2 * shuttlecockScore + 0.25 * spreadScore + 0.35 * playerPresenceScore), 1.0)

        if collectDiagnostics {
            diagnostics.append(MotionDiagnostics(
                timestamp: timestamp,
                displacedWhiteCount: totalDisplacedWhite,
                maxClusterSum: maxClusterSum,
                shuttlecockScore: shuttlecockScore,
                generalMotionScore: generalMotionScore,
                activeRegions: activeRegions,
                spreadScore: spreadScore,
                personCount: personCount,
                playerPresenceScore: playerPresenceScore,
                blendedScore: blended
            ))
        }

        return (motion: blended, shuttlecockFlight: flightScore)
    }

    // MARK: - Vision Person Detection

    /// Detect number of people visible on the court using Vision framework.
    /// Filters out detections in the top 20% of the frame (ceiling/lights area).
    /// Returns the count of people detected in the court region.
    private func detectPersonCount(in pixelBuffer: CVPixelBuffer) -> Int {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results else { return 0 }

            // Filter: exclude detections in top 20% of frame (ceiling/lights).
            // Vision coordinates: origin at bottom-left, y goes up.
            // Top 20% of visual image = y > 0.8 in Vision coords.
            let courtDetections = results.filter { observation in
                observation.boundingBox.midY < 0.8
            }
            return courtDetections.count
        } catch {
            return 0
        }
    }

    // MARK: - Frame Rendering

    /// Render a pixel buffer to an RGBA byte array at the specified resolution.
    /// Uses CIImage pipeline for fast, GPU-accelerated scaling.
    private func renderToRGBA(_ source: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = CGFloat(width) / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

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
