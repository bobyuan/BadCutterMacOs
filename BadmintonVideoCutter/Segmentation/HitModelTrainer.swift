import Foundation
import AVFoundation
import CreateML
import CoreML

final class HitModelTrainer {

    struct TrainingResult {
        var accuracy: Double
        var modelURL: URL
        var clipCount: Int
    }

    enum TrainerError: LocalizedError {
        case noAudioTrack
        case insufficientData(rally: Int, background: Int)
        case trainingFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "Video has no audio track."
            case .insufficientData(let rally, let background):
                return "Not enough training data: \(rally) rally clips, \(background) background clips. Need at least 15 of each."
            case .trainingFailed(let msg):
                return "Training failed: \(msg)"
            case .exportFailed(let msg):
                return "Failed to export model: \(msg)"
            }
        }
    }

    /// Train a sound classifier from corrected game data.
    /// `featureFrames` provides per-frame audio scores from the heuristic analysis,
    /// used to select only the high-activity portions within each rally for "rally" clips.
    static func train(
        videoURL: URL,
        games: [Game],
        featureFrames: [FeatureFrame],
        outputModelURL: URL,
        progress: @escaping (String) -> Void
    ) async throws -> TrainingResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hit_trainer_\(UUID().uuidString)")
        let rallyDir = tempDir.appendingPathComponent("rally")
        let backgroundDir = tempDir.appendingPathComponent("background")

        try FileManager.default.createDirectory(at: rallyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backgroundDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress("Reading audio...")
        let pcmData = try await readFullPCMAudio(from: videoURL)
        guard !pcmData.samples.isEmpty else {
            throw TrainerError.noAudioTrack
        }

        // Build a lookup of audio activity scores by time
        let activityScores = buildActivityLookup(from: featureFrames)

        progress("Extracting rally clips...")
        let rallyClipCount = try extractRallyClips(
            from: pcmData, games: games, activityScores: activityScores, outputDir: rallyDir
        )

        progress("Extracting background clips...")
        let bgClipCount = try extractBackgroundClips(
            from: pcmData, games: games, activityScores: activityScores, outputDir: backgroundDir
        )

        let minClips = 15
        guard rallyClipCount >= minClips, bgClipCount >= minClips else {
            throw TrainerError.insufficientData(rally: rallyClipCount, background: bgClipCount)
        }

        progress("Training model (\(rallyClipCount + bgClipCount) clips)...")

        let result = try await trainModel(
            dataDir: tempDir,
            outputURL: outputModelURL,
            totalClips: rallyClipCount + bgClipCount,
            progress: progress
        )

        return result
    }

    // MARK: - Activity Lookup

    /// Build a sorted array of (timestamp, audioScore) for binary-search lookup.
    private static func buildActivityLookup(from frames: [FeatureFrame]) -> [(time: TimeInterval, score: Double)] {
        return frames.map { (time: $0.timestamp, score: $0.audioScore) }
    }

    /// Get the average audio activity score for a 1-second window starting at `time`.
    private static func activityScore(at time: TimeInterval, duration: TimeInterval = 1.0, in scores: [(time: TimeInterval, score: Double)]) -> Double {
        guard !scores.isEmpty else { return 0 }
        let end = time + duration
        // Find frames within this window
        let relevant = scores.filter { $0.time >= time && $0.time < end }
        guard !relevant.isEmpty else { return 0 }
        return relevant.map(\.score).reduce(0, +) / Double(relevant.count)
    }

    // MARK: - Clip Extraction

    /// Extract "rally" clips only from high-activity portions within each rally segment.
    /// Uses the heuristic audio scores to avoid picking up bird-fetching / walking sections.
    private static func extractRallyClips(
        from pcm: PCMAudio,
        games: [Game],
        activityScores: [(time: TimeInterval, score: Double)],
        outputDir: URL
    ) throws -> Int {
        let activePoints = games.flatMap(\.points).filter { $0.reviewStatus != .deleted }
        var clipIndex = 0

        for point in activePoints {
            let start = point.start + 0.5
            let end = point.end - 0.5
            guard end - start >= 1.0 else { continue }

            // Compute per-second activity scores within this rally
            var windowScores: [(time: TimeInterval, score: Double)] = []
            var t = start
            while t + 1.0 <= end {
                let score = activityScore(at: t, in: activityScores)
                windowScores.append((time: t, score: score))
                t += 0.5  // evaluate every 0.5s for finer granularity
            }

            // Find threshold: use median score within this rally.
            // Only clips above median qualify as "rally" training data.
            let sorted = windowScores.map(\.score).sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let threshold = max(median, 0.1)  // at least 0.1 to avoid totally silent clips

            // Extract 1-second clips at 1-second intervals, only where activity is above threshold
            t = start
            while t + 1.0 <= end {
                let score = activityScore(at: t, in: activityScores)
                if score >= threshold {
                    let clip = extractClip(from: pcm, start: t, duration: 1.0)
                    if !clip.isEmpty {
                        let url = outputDir.appendingPathComponent("clip_\(clipIndex).wav")
                        writeWAV(samples: clip, sampleRate: Int(pcm.sampleRate), to: url)
                        clipIndex += 1
                    }
                }
                t += 1.0
            }
        }

        return clipIndex
    }

    /// Extract "background" clips from gaps between points AND from the low-activity
    /// tails within rally segments (the bird-picking / walking portions).
    private static func extractBackgroundClips(
        from pcm: PCMAudio,
        games: [Game],
        activityScores: [(time: TimeInterval, score: Double)],
        outputDir: URL
    ) throws -> Int {
        let activePoints = games.flatMap(\.points)
            .filter { $0.reviewStatus != .deleted }
            .sorted { $0.start < $1.start }

        var clipIndex = 0

        // Source 1: Gaps between rally segments
        var gaps: [(start: TimeInterval, end: TimeInterval)] = []

        if activePoints.count > 1 {
            for i in 0..<activePoints.count - 1 {
                let gapStart = activePoints[i].end
                let gapEnd = activePoints[i + 1].start
                if gapEnd - gapStart > 1.5 {
                    gaps.append((start: gapStart + 0.25, end: gapEnd - 0.25))
                }
            }
        }

        if let first = activePoints.first, first.start > 2.0 {
            gaps.insert((start: 0.5, end: first.start - 0.5), at: 0)
        }

        let totalDuration = Double(pcm.samples.count) / pcm.sampleRate
        if let last = activePoints.last, totalDuration - last.end > 2.0 {
            gaps.append((start: last.end + 0.5, end: totalDuration - 0.5))
        }

        for gap in gaps {
            var t = gap.start
            while t + 1.0 <= gap.end {
                let clip = extractClip(from: pcm, start: t, duration: 1.0)
                if !clip.isEmpty {
                    let url = outputDir.appendingPathComponent("clip_\(clipIndex).wav")
                    writeWAV(samples: clip, sampleRate: Int(pcm.sampleRate), to: url)
                    clipIndex += 1
                }
                t += 1.0
            }
        }

        // Source 2: Low-activity tails within rally segments (bird-picking, walking)
        for point in activePoints {
            let start = point.start + 0.5
            let end = point.end - 0.5
            guard end - start >= 2.0 else { continue }

            let sorted = {
                var scores: [Double] = []
                var t = start
                while t + 1.0 <= end {
                    scores.append(activityScore(at: t, in: activityScores))
                    t += 1.0
                }
                return scores.sorted()
            }()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            // Low-activity threshold: well below the median
            let lowThreshold = median * 0.4

            var t = start
            while t + 1.0 <= end {
                let score = activityScore(at: t, in: activityScores)
                if score <= lowThreshold {
                    let clip = extractClip(from: pcm, start: t, duration: 1.0)
                    if !clip.isEmpty {
                        let url = outputDir.appendingPathComponent("clip_\(clipIndex).wav")
                        writeWAV(samples: clip, sampleRate: Int(pcm.sampleRate), to: url)
                        clipIndex += 1
                    }
                }
                t += 1.0
            }
        }

        return clipIndex
    }

    private static func extractClip(from pcm: PCMAudio, start: TimeInterval, duration: TimeInterval) -> [Float] {
        let startSample = Int(start * pcm.sampleRate)
        let sampleCount = Int(duration * pcm.sampleRate)
        let endSample = startSample + sampleCount

        guard startSample >= 0, endSample <= pcm.samples.count else { return [] }
        return Array(pcm.samples[startSample..<endSample])
    }

    // MARK: - Training

    private static func trainModel(
        dataDir: URL,
        outputURL: URL,
        totalClips: Int,
        progress: @escaping (String) -> Void
    ) async throws -> TrainingResult {
        return try await Task.detached {
            let dataSource = MLSoundClassifier.DataSource.labeledDirectories(at: dataDir)

            let params = MLSoundClassifier.ModelParameters(
                validation: .split(strategy: .automatic),
                maxIterations: 20
            )

            let classifier: MLSoundClassifier
            do {
                classifier = try MLSoundClassifier(trainingData: dataSource, parameters: params)
            } catch {
                throw TrainerError.trainingFailed(error.localizedDescription)
            }

            let accuracy = Double(classifier.trainingMetrics.classificationError)
            let modelAccuracy = max(0, 1.0 - accuracy)

            // Ensure parent directory exists
            let parentDir = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Write to a temp .mlmodel file, then compile to .mlmodelc
            let tempModelURL = parentDir.appendingPathComponent("hit_classifier_temp.mlmodel")
            defer { try? FileManager.default.removeItem(at: tempModelURL) }

            do {
                try classifier.write(to: tempModelURL)
            } catch {
                throw TrainerError.exportFailed(error.localizedDescription)
            }

            // Compile .mlmodel → .mlmodelc
            let compiledURL: URL
            do {
                compiledURL = try MLModel.compileModel(at: tempModelURL)
            } catch {
                throw TrainerError.exportFailed("Model compilation failed: \(error.localizedDescription)")
            }

            // Move compiled model to final location
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            do {
                try FileManager.default.moveItem(at: compiledURL, to: outputURL)
            } catch {
                throw TrainerError.exportFailed("Failed to save compiled model: \(error.localizedDescription)")
            }

            return TrainingResult(
                accuracy: modelAccuracy,
                modelURL: outputURL,
                clipCount: totalClips
            )
        }.value
    }

    // MARK: - PCM Audio Reading

    private struct PCMAudio {
        var samples: [Float]
        var sampleRate: Double
    }

    private static func readFullPCMAudio(from videoURL: URL) async throws -> PCMAudio {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TrainerError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        var allSamples: [Float] = []
        reader.startReading()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { continue }
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        return PCMAudio(samples: allSamples, sampleRate: 44100.0)
    }

    // MARK: - WAV Writing

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) {
        // Convert Float32 to Int16 for WAV
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        var pcmData = Data(capacity: int16Samples.count * 2)
        for sample in int16Samples {
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }

        var header = Data()
        let dataSize = UInt32(pcmData.count)
        let fileSize = dataSize + 36

        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        let byteRate = UInt32(sampleRate * 2)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var fileData = header
        fileData.append(pcmData)
        try? fileData.write(to: url)
    }
}
