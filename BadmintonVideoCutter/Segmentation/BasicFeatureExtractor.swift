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

    // Shuttlecock flight score smoothing.
    // The raw per-frame velocity measurement is noisy, so we apply EMA smoothing.
    // During rallies, the shuttlecock moves continuously → sustained high score.
    // During breaks, no fast white movement → sustained low score.
    private var flightScoreEMA: Double = 0

    struct ProgressCallbacks {
        var onAudioProgress: @MainActor (Double) -> Void
        var onVideoProgress: @MainActor (Double) -> Void
    }

    /// Calibration priors: normalized (0-1) positions of the shuttlecock at known timestamps.
    /// Used to learn shuttlecock appearance and bias cluster selection.
    struct CalibrationPrior {
        var timestamp: TimeInterval
        var position: CGPoint  // normalized 0-1
    }

    /// Learned shuttlecock appearance from calibration data.
    /// Overrides hardcoded detection thresholds with video-specific values.
    struct ShuttlecockProfile {
        var luminanceThreshold: Int    // min brightness to count as "shuttlecock-like"
        var saturationThreshold: Int   // max saturation
        var medianLuminance: Int       // typical brightness of the bird
    }

    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame] {
        return try await extractFeatures(from: videoURL, mlModelURL: nil, progress: nil)
    }

    func extractFeatures(from videoURL: URL, mlModelURL: URL? = nil, progress: ProgressCallbacks?, calibrationPriors: [CalibrationPrior] = [], shuttlecockModelURL: URL? = nil) async throws -> [FeatureFrame] {
        let asset = AVURLAsset(url: videoURL)
        let totalDuration = try await asset.load(.duration).seconds

        async let videoFrames = extractVideoFeatures(from: videoURL, totalDuration: totalDuration, progress: progress, calibrationPriors: calibrationPriors, shuttlecockModelURL: shuttlecockModelURL)
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

    private func extractVideoFeatures(from videoURL: URL, totalDuration: TimeInterval, progress: ProgressCallbacks?, calibrationPriors: [CalibrationPrior] = [], shuttlecockModelURL: URL? = nil) async throws -> [FeatureFrame] {
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

        // Profile shuttlecock appearance from calibration data (if available)
        let shuttlecockProfile: ShuttlecockProfile?
        if !calibrationPriors.isEmpty {
            shuttlecockProfile = profileShuttlecock(videoURL: videoURL, priors: calibrationPriors,
                                                     width: analysisWidth, height: analysisHeight)
        } else {
            shuttlecockProfile = nil
        }

        // Initialize ML shuttlecock detector if model is available
        var shuttlecockDetector: ShuttlecockDetector?
        if let modelURL = shuttlecockModelURL {
            do {
                shuttlecockDetector = try ShuttlecockDetector(modelURL: modelURL)
                print("ML shuttlecock detector initialized")
            } catch {
                print("Failed to load shuttlecock ML model: \(error). Falling back to blob detection.")
                shuttlecockDetector = nil
            }
        }
        let useMLDetector = shuttlecockDetector != nil

        diagnostics = []
        lastPersonCount = 0
        personDetectionCounter = 0
        flightScoreEMA = 0

        // When using ML detector, we need to buffer pending frames
        // because the detector returns results in batches of seqLen (3).
        var pendingFrameIndices: [(index: Int, timestamp: TimeInterval)] = []

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

            // Compute motion scores (always needed for blended motion score)
            let priorHint: CGPoint? = nearestCalibrationPrior(at: timestamp, priors: calibrationPriors)
            let scores: (motion: Double, shuttlecockFlight: Double, shuttlecockPos: (x: Double, y: Double)?)
            if let prev = previousRGBA {
                scores = computeMotionScore(prev, currentRGBA, width: analysisWidth, height: analysisHeight, timestamp: timestamp, personCount: lastPersonCount, calibrationHint: priorHint, profile: shuttlecockProfile)
            } else {
                scores = (motion: 0, shuttlecockFlight: 0, shuttlecockPos: nil)
            }
            previousRGBA = currentRGBA

            if useMLDetector, let detector = shuttlecockDetector {
                // Use ML detector for shuttlecock — blob results used only for motion score
                let frameIdx = frames.count
                frames.append(FeatureFrame(
                    timestamp: timestamp,
                    motionScore: scores.motion,
                    audioScore: 0.0,
                    shuttlecockFlightScore: 0,
                    shuttlecockPosition: nil
                ))
                pendingFrameIndices.append((index: frameIdx, timestamp: timestamp))

                // Feed frame to ML detector
                if let detections = detector.processFrame(rgba: currentRGBA, width: analysisWidth, height: analysisHeight, timestamp: timestamp) {
                    // Assign ML-detected positions to their corresponding FeatureFrames
                    for detection in detections {
                        if let pendingIdx = pendingFrameIndices.first(where: { abs($0.timestamp - detection.timestamp) < 0.01 }) {
                            frames[pendingIdx.index].shuttlecockPosition = detection.position
                            frames[pendingIdx.index].shuttlecockFlightScore = detection.confidence
                        }
                    }
                    // Remove assigned pending frames
                    let assignedTimestamps = Set(detections.map(\.timestamp))
                    pendingFrameIndices.removeAll { pending in
                        assignedTimestamps.contains(where: { abs($0 - pending.timestamp) < 0.01 })
                    }
                }
            } else {
                // Fallback: use blob detection for shuttlecock
                frames.append(FeatureFrame(
                    timestamp: timestamp,
                    motionScore: scores.motion,
                    audioScore: 0.0,
                    shuttlecockFlightScore: scores.shuttlecockFlight,
                    shuttlecockPosition: scores.shuttlecockPos
                ))
            }

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

        // Flush remaining ML detector buffer
        if let detector = shuttlecockDetector, let detections = detector.flush() {
            for detection in detections {
                if let pendingIdx = pendingFrameIndices.first(where: { abs($0.timestamp - detection.timestamp) < 0.01 }) {
                    frames[pendingIdx.index].shuttlecockPosition = detection.position
                    frames[pendingIdx.index].shuttlecockFlightScore = detection.confidence
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

    // MARK: - Calibration Profiling

    /// Sample pixel values at each calibrated shuttlecock position to learn
    /// what the bird actually looks like in this video (brightness, color).
    /// Returns a ShuttlecockProfile with video-specific thresholds.
    private func profileShuttlecock(videoURL: URL, priors: [CalibrationPrior],
                                     width: Int, height: Int) -> ShuttlecockProfile? {
        guard !priors.isEmpty else { return nil }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var luminances: [Int] = []
        var saturations: [Int] = []

        for prior in priors {
            let cmTime = CMTime(seconds: prior.timestamp, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }

            // Render to RGBA at analysis resolution
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &rgba, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Sample a small patch around the labeled position (5x5 pixels)
            let cx = Int(Double(prior.position.x) * Double(width))
            let cy = Int(Double(prior.position.y) * Double(height))
            let patchRadius = 4

            for dy in -patchRadius...patchRadius {
                for dx in -patchRadius...patchRadius {
                    let px = max(0, min(width - 1, cx + dx))
                    let py = max(0, min(height - 1, cy + dy))
                    let idx = (py * width + px) * 4
                    let r = Int(rgba[idx])
                    let g = Int(rgba[idx + 1])
                    let b = Int(rgba[idx + 2])
                    let lum = (r * 77 + g * 150 + b * 29) >> 8
                    let sat = max(r, max(g, b)) - min(r, min(g, b))
                    luminances.append(lum)
                    saturations.append(sat)
                }
            }
        }

        guard !luminances.isEmpty else { return nil }

        let sortedLum = luminances.sorted()
        let sortedSat = saturations.sorted()
        let medianLum = sortedLum[sortedLum.count / 2]
        let p90Sat = sortedSat[min(sortedSat.count - 1, Int(Double(sortedSat.count) * 0.9))]

        // Set threshold to capture most of the bird: p10 luminance - margin
        let p10Lum = sortedLum[max(0, Int(Double(sortedLum.count) * 0.10))]
        let lumThreshold = max(80, p10Lum - 20)
        let satThreshold = max(60, p90Sat + 20)

        print("Calibration profile: medianLum=\(medianLum), lumThreshold=\(lumThreshold), satThreshold=\(satThreshold) (from \(priors.count) labeled frames)")

        return ShuttlecockProfile(
            luminanceThreshold: lumThreshold,
            saturationThreshold: satThreshold,
            medianLuminance: medianLum
        )
    }

    // MARK: - Calibration Prior Lookup

    /// Find the nearest calibration prior within 5 seconds of the given timestamp.
    /// Interpolates between the two nearest priors if the frame falls between them.
    private func nearestCalibrationPrior(at timestamp: TimeInterval, priors: [CalibrationPrior]) -> CGPoint? {
        guard !priors.isEmpty else { return nil }

        // Find the closest prior by timestamp
        var bestDist = Double.greatestFiniteMagnitude
        var bestIdx = 0
        for (i, p) in priors.enumerated() {
            let d = abs(p.timestamp - timestamp)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        // Only use if within 5 seconds
        guard bestDist <= 5.0 else { return nil }

        // Try to interpolate between two bracketing priors
        let sorted = priors.sorted { $0.timestamp < $1.timestamp }
        var before: CalibrationPrior?
        var after: CalibrationPrior?
        for p in sorted {
            if p.timestamp <= timestamp { before = p }
            if p.timestamp >= timestamp && after == nil { after = p }
        }

        if let b = before, let a = after, a.timestamp != b.timestamp {
            let t = (timestamp - b.timestamp) / (a.timestamp - b.timestamp)
            return CGPoint(
                x: b.position.x + (a.position.x - b.position.x) * t,
                y: b.position.y + (a.position.y - b.position.y) * t
            )
        }

        return priors[bestIdx].position
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

    /// Detect shuttlecock via motion-based small-blob detection.
    /// Instead of filtering by color (white pixels), this detects ALL moving pixels,
    /// clusters them, then selects the smallest+fastest blob as the shuttlecock.
    ///
    /// Key insight: players are large slow blobs; the shuttlecock is a tiny fast blob.
    /// Scoring: speed / sqrt(size) — small fast objects score highest.
    ///
    /// Returns (blendedMotionScore, shuttlecockFlightScore, shuttlecockPosition)
    private func computeMotionScore(_ prevRGBA: [UInt8], _ currRGBA: [UInt8], width: Int, height: Int, timestamp: TimeInterval = 0, personCount: Int = 0, calibrationHint: CGPoint? = nil, profile: ShuttlecockProfile? = nil) -> (motion: Double, shuttlecockFlight: Double, shuttlecockPos: (x: Double, y: Double)?) {
        // Skip top 20% (ceiling/lights in indoor courts)
        let startRow = height / 5
        let noiseThreshold: Int = 15

        // Fine grid for shuttlecock detection: track all motion, not just white pixels.
        // cellSize=8 → 3x3 cluster = 24x24px. Shuttlecock is ~10-20px at 960px.
        let cellSize = 8
        let gridW = (width + cellSize - 1) / cellSize
        let gridH = ((height - startRow) + cellSize - 1) / cellSize
        var motionGrid = [Int](repeating: 0, count: gridW * gridH)      // moving pixel count
        var intensityGrid = [Double](repeating: 0, count: gridW * gridH) // sum of motion intensity

        // Coarse grid for multi-region motion spread (rally vs break detection)
        let spreadCols = 6
        let spreadRows = 4
        let spreadCellW = max(1, width / spreadCols)
        let spreadCellH = max(1, (height - startRow) / spreadRows)
        let spreadCellCount = spreadCols * spreadRows
        var spreadMoving = [Int](repeating: 0, count: spreadCellCount)
        var spreadTotal = [Int](repeating: 0, count: spreadCellCount)

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

                let cR = Int(currRGBA[rgbaIdx])
                let cG = Int(currRGBA[rgbaIdx + 1])
                let cB = Int(currRGBA[rgbaIdx + 2])
                let pR = Int(prevRGBA[rgbaIdx])
                let pG = Int(prevRGBA[rgbaIdx + 1])
                let pB = Int(prevRGBA[rgbaIdx + 2])

                // Per-channel diff (more sensitive than luminance-only)
                let diff = abs(cR - pR) + abs(cG - pG) + abs(cB - pB)

                regionPixels += 1
                spreadTotal[sIdx] += 1

                let currLum = (cR * 77 + cG * 150 + cB * 29) >> 8
                let prevLum = (pR * 77 + pG * 150 + pB * 29) >> 8
                let lumDiff = abs(currLum - prevLum)

                if diff > noiseThreshold * 2 {
                    // This pixel changed between frames (RGB sum diff > 30)
                    if gridY < gridH && gridX < gridW {
                        let gi = gridY * gridW + gridX
                        motionGrid[gi] += 1
                        intensityGrid[gi] += Double(diff)
                    }
                }

                if lumDiff > 12 {
                    movingPixels += 1
                    totalDiff += lumDiff
                    spreadMoving[sIdx] += 1
                }
            }
        }

        // --- Shuttlecock detection: find motion blobs and score by speed/size ---
        //
        // Extract blobs from the motion grid. Each blob is a connected cluster of
        // cells with significant motion. Then for each pair of blobs in the current
        // frame vs previous frame's blobs, compute displacement.
        //
        // Simpler approach: find top-N motion clusters, measure their size (pixel count).
        // The shuttlecock blob is SMALL (5-30 moving pixels in the grid).
        // Player blobs are LARGE (50-500+ moving pixels).
        // Score = intensity / size — small bright blobs win.

        let resolutionScale = Double(width) / 960.0
        let minBlobPixels = max(2, Int(3.0 * resolutionScale * resolutionScale))

        let blobs = findTopClustersWithIntensity(motionGrid: motionGrid, intensityGrid: intensityGrid,
                                                  gridW: gridW, gridH: gridH,
                                                  cellSize: cellSize, startRow: startRow,
                                                  minPixels: minBlobPixels, maxClusters: 10)

        // Score ALL blobs by intensity/size ratio. No hard size cutoff — the scoring
        // naturally favors small intense blobs (shuttlecock) over large ones (players).
        // score = avgIntensity / size^0.7  (stronger size penalty than sqrt)
        var bestBlobScore: Double = 0
        var bestBlob: (x: Double, y: Double, pixels: Int, totalIntensity: Double)? = nil

        for blob in blobs {
            let avgIntensity = blob.totalIntensity / max(1.0, Double(blob.pixels))
            // size^0.7 penalizes large blobs more aggressively than sqrt
            let sizePenalty = pow(Double(blob.pixels), 0.7)
            var score = avgIntensity / sizePenalty

            // Calibration proximity boost
            if let hint = calibrationHint {
                let normX = blob.x / Double(width)
                let normY = blob.y / Double(height)
                let dx = normX - Double(hint.x)
                let dy = normY - Double(hint.y)
                let distToHint = sqrt(dx * dx + dy * dy)
                score *= 1.0 + 2.0 * exp(-distToHint * distToHint / (2 * 0.08 * 0.08))
            }

            if score > bestBlobScore {
                bestBlobScore = score
                bestBlob = blob
            }
        }

        // Debug: log blob stats every ~2 seconds
        if Int(timestamp * 5) % 10 == 0 {
            if blobs.isEmpty {
                print(String(format: "t=%.1f NO BLOBS (motionGrid max=%d)", timestamp, motionGrid.max() ?? 0))
            } else {
                let sizes = blobs.map(\.pixels)
                print(String(format: "t=%.1f blobs=%d sizes=%@ bestScore=%.1f bestPx=%d avgInt=%.0f",
                             timestamp, blobs.count, sizes.description,
                             bestBlobScore, bestBlob?.pixels ?? 0,
                             (bestBlob?.totalIntensity ?? 0) / max(1, Double(bestBlob?.pixels ?? 1))))
            }
        }

        // Compute flight score. Use the best blob's score relative to thresholds.
        let rawFlightScore: Double
        if bestBlob != nil {
            let threshold = 3.0 * resolutionScale
            let ceiling = 20.0 * resolutionScale
            rawFlightScore = min(max(bestBlobScore - threshold, 0) / (ceiling - threshold), 1.0)
        } else {
            rawFlightScore = 0
        }

        // EMA smoothing
        flightScoreEMA = flightScoreEMA * 0.5 + rawFlightScore * 0.5
        let shuttlecockScore = flightScoreEMA
        let flightScore = flightScoreEMA

        // General motion score (unchanged)
        let generalMotionScore: Double
        if regionPixels > 0, movingPixels > 0 {
            let motionFraction = Double(movingPixels) / Double(regionPixels)
            let avgIntensity = Double(totalDiff) / Double(movingPixels) / 255.0
            let raw = motionFraction * 0.6 + avgIntensity * 0.4
            generalMotionScore = min(raw * 4.0, 1.0)
        } else {
            generalMotionScore = 0
        }

        // Multi-region spread (unchanged)
        let spreadActiveThreshold = 0.015
        var activeRegions = 0
        for i in 0..<spreadCellCount {
            if spreadTotal[i] > 0 {
                let fraction = Double(spreadMoving[i]) / Double(spreadTotal[i])
                if fraction > spreadActiveThreshold {
                    activeRegions += 1
                }
            }
        }
        let spreadScore = min(Double(activeRegions) / 8.0, 1.0)

        // Player presence (unchanged)
        let playerPresenceScore: Double
        switch personCount {
        case 3...: playerPresenceScore = 1.0
        case 2:    playerPresenceScore = 0.85
        case 1:    playerPresenceScore = 0.3
        default:   playerPresenceScore = 0.0
        }

        let blended = min(generalMotionScore * (0.2 + 0.2 * shuttlecockScore + 0.25 * spreadScore + 0.35 * playerPresenceScore), 1.0)

        let maxClusterSum = blobs.first?.pixels ?? 0

        if collectDiagnostics {
            diagnostics.append(MotionDiagnostics(
                timestamp: timestamp,
                displacedWhiteCount: blobs.reduce(0) { $0 + $1.pixels },
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

        // Shuttlecock position from the best small-fast blob
        let shuttlecockPos: (x: Double, y: Double)?
        if let blob = bestBlob, rawFlightScore > 0.1 {
            shuttlecockPos = (x: blob.x / Double(width), y: blob.y / Double(height))
        } else {
            shuttlecockPos = nil
        }

        return (motion: blended, shuttlecockFlight: flightScore, shuttlecockPos: shuttlecockPos)
    }

    // MARK: - Cluster Detection

    /// Find the top-N clusters of motion pixels in a grid.
    /// Returns clusters sorted by density (most pixels first).
    /// Each cluster is a 3x3 neighborhood around a peak cell.
    /// Clusters don't overlap (cells are marked as used after each extraction).
    private func findTopClusters(in grid: [Int], gridW: Int, gridH: Int,
                                  cellSize: Int, startRow: Int,
                                  minPixels: Int, maxClusters: Int) -> [(x: Double, y: Double, pixels: Int)] {
        var result: [(x: Double, y: Double, pixels: Int)] = []
        var usedCells = Set<Int>()

        for _ in 0..<maxClusters {
            // Find highest unused cell
            var maxCount = 0
            var maxGX = 0, maxGY = 0
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    let idx = gy * gridW + gx
                    guard !usedCells.contains(idx) else { continue }
                    let c = grid[idx]
                    if c > maxCount {
                        maxCount = c
                        maxGX = gx
                        maxGY = gy
                    }
                }
            }
            guard maxCount > 0 else { break }

            // Compute weighted centroid from 3x3 neighborhood and mark as used
            var totalPixels = 0
            var wX = 0.0, wY = 0.0, wTotal = 0.0
            for dy in -1...1 {
                for dx in -1...1 {
                    let gx = maxGX + dx, gy = maxGY + dy
                    guard gx >= 0 && gx < gridW && gy >= 0 && gy < gridH else { continue }
                    let idx = gy * gridW + gx
                    usedCells.insert(idx)
                    let w = Double(grid[idx])
                    totalPixels += grid[idx]
                    wX += Double(gx * cellSize + cellSize / 2) * w
                    wY += Double(gy * cellSize + cellSize / 2 + startRow) * w
                    wTotal += w
                }
            }

            guard totalPixels >= minPixels && wTotal > 0 else { continue }
            result.append((x: wX / wTotal, y: wY / wTotal, pixels: totalPixels))
        }

        return result
    }

    /// Find top-N motion clusters with their total intensity.
    /// Like findTopClusters but also sums intensityGrid values for proper scoring.
    private func findTopClustersWithIntensity(
        motionGrid: [Int], intensityGrid: [Double],
        gridW: Int, gridH: Int, cellSize: Int, startRow: Int,
        minPixels: Int, maxClusters: Int
    ) -> [(x: Double, y: Double, pixels: Int, totalIntensity: Double)] {
        var result: [(x: Double, y: Double, pixels: Int, totalIntensity: Double)] = []
        var usedCells = Set<Int>()

        for _ in 0..<maxClusters {
            var maxCount = 0
            var maxGX = 0, maxGY = 0
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    let idx = gy * gridW + gx
                    guard !usedCells.contains(idx) else { continue }
                    if motionGrid[idx] > maxCount {
                        maxCount = motionGrid[idx]
                        maxGX = gx
                        maxGY = gy
                    }
                }
            }
            guard maxCount > 0 else { break }

            var totalPixels = 0
            var totalIntensity = 0.0
            var wX = 0.0, wY = 0.0, wTotal = 0.0
            for dy in -1...1 {
                for dx in -1...1 {
                    let gx = maxGX + dx, gy = maxGY + dy
                    guard gx >= 0 && gx < gridW && gy >= 0 && gy < gridH else { continue }
                    let idx = gy * gridW + gx
                    usedCells.insert(idx)
                    let w = Double(motionGrid[idx])
                    totalPixels += motionGrid[idx]
                    totalIntensity += intensityGrid[idx]
                    wX += Double(gx * cellSize + cellSize / 2) * w
                    wY += Double(gy * cellSize + cellSize / 2 + startRow) * w
                    wTotal += w
                }
            }

            guard totalPixels >= minPixels && wTotal > 0 else { continue }
            result.append((x: wX / wTotal, y: wY / wTotal, pixels: totalPixels, totalIntensity: totalIntensity))
        }

        return result
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
                audioScore: audioScore,
                shuttlecockFlightScore: frame.shuttlecockFlightScore,
                shuttlecockPosition: frame.shuttlecockPosition
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
