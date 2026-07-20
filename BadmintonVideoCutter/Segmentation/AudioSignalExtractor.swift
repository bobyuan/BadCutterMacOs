import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis

/// Sparse audio-derived signals computed once per video from the audio track
/// (no video decode) and cached in the session directory.
struct AudioSignals: Codable, Equatable {
    struct CheerSample: Codable, Equatable {
        var t: TimeInterval
        var score: Double
    }

    /// Energy-onset timestamps (racket impacts, DESIGN §5.1 audio upgrade).
    var onsets: [TimeInterval] = []
    /// Crowd-excitement confidence over time (applause/cheering/crowd from
    /// Apple's built-in sound classifier), ~0.5s apart.
    var cheer: [CheerSample] = []

    var isEmpty: Bool { onsets.isEmpty && cheer.isEmpty }
}

enum AudioSignalExtractor {

    /// Best-effort extraction; returns empty signals when the video has no
    /// audio track or analysis fails.
    static func extract(from videoURL: URL) async -> AudioSignals {
        guard let pcm = try? await readPCM(from: videoURL) else { return AudioSignals() }
        var signals = AudioSignals()
        signals.onsets = detectOnsets(samples: pcm.samples, sampleRate: pcm.sampleRate)
        signals.cheer = (try? await classifyCheer(samples: pcm.samples, sampleRate: pcm.sampleRate)) ?? []
        return signals
    }

    // MARK: - Onset Detection (vDSP energy flux)

    /// Energy-peak onset detection: RMS envelope over 256-sample hops,
    /// half-wave-rectified flux, locally adaptive threshold, peak picking
    /// with 0.12s minimum spacing. Pure and deterministic.
    static func detectOnsets(samples: [Float], sampleRate: Double) -> [TimeInterval] {
        let hop = 256
        let window = 512
        guard samples.count > window * 4, sampleRate > 0 else { return [] }

        // RMS envelope.
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hop)
        var i = 0
        while i + window <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_rmsqv(buf.baseAddress! + i, 1, &rms, vDSP_Length(window))
            }
            envelope.append(rms)
            i += hop
        }
        guard envelope.count > 8 else { return [] }

        // Half-wave rectified flux (energy rises only).
        var flux: [Float] = [0]
        for j in 1..<envelope.count {
            flux.append(max(0, envelope[j] - envelope[j - 1]))
        }

        // Locally adaptive threshold: mean flux over ±1s, scaled, plus a
        // floor tied to the global peak so silence doesn't trigger.
        let hopsPerSecond = Int(sampleRate / Double(hop))
        let half = max(1, hopsPerSecond)
        var globalMax: Float = 0
        vDSP_maxv(flux, 1, &globalMax, vDSP_Length(flux.count))
        guard globalMax > 0 else { return [] }

        var prefix: [Float] = [0]
        prefix.reserveCapacity(flux.count + 1)
        for value in flux { prefix.append(prefix.last! + value) }
        func localMean(_ j: Int) -> Float {
            let lo = max(0, j - half)
            let hi = min(flux.count - 1, j + half)
            return (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }

        let minSpacing = 0.12
        var onsets: [TimeInterval] = []
        for j in 1..<flux.count - 1 {
            let value = flux[j]
            guard value > 2.5 * localMean(j) + 0.05 * globalMax,
                  value >= flux[j - 1], value >= flux[j + 1] else { continue }
            let t = Double(j) * Double(hop) / sampleRate
            if let last = onsets.last, t - last < minSpacing { continue }
            onsets.append(t)
        }
        return onsets
    }

    // MARK: - Crowd Excitement (built-in sound classifier)

    private static let cheerLabels: Set<String> = ["applause", "cheering", "crowd"]

    private static func classifyCheer(samples: [Float], sampleRate: Double) async throws -> [AudioSignals.CheerSample] {
        // SoundAnalysis wants a file; write a temp WAV.
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }
        try writeWAV(samples: samples, sampleRate: Int(sampleRate), to: tempWAV)

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 44100)
        request.overlapFactor = 0.5

        let analyzer = try SNAudioFileAnalyzer(url: tempWAV)
        let observer = CheerObserver(labels: cheerLabels)
        try analyzer.add(request, withObserver: observer)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            observer.onComplete = { continuation.resume() }
            analyzer.analyze()
        }
        if let error = observer.error { throw error }
        return observer.samples
    }

    private final class CheerObserver: NSObject, SNResultsObserving {
        let labels: Set<String>
        var samples: [AudioSignals.CheerSample] = []
        var error: Error?
        var onComplete: (() -> Void)?

        init(labels: Set<String>) {
            self.labels = labels
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            let t = classification.timeRange.start.seconds + classification.timeRange.duration.seconds / 2
            let score = labels
                .compactMap { classification.classification(forIdentifier: $0)?.confidence }
                .max() ?? 0
            samples.append(AudioSignals.CheerSample(t: t, score: Double(score)))
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            self.error = error
            onComplete?()
        }

        func requestDidComplete(_ request: SNRequest) {
            onComplete?()
        }
    }

    // MARK: - PCM I/O

    private struct PCM {
        var samples: [Float]
        var sampleRate: Double
    }

    private static func readPCM(from videoURL: URL) async throws -> PCM {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioSignalExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track"])
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

        var samples: [Float] = []
        reader.startReading()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { continue }
            let count = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) {
                samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: count))
            }
        }
        return PCM(samples: samples, sampleRate: 44100)
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let int16Samples = samples.map { sample -> Int16 in
            Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
        var pcmData = Data(capacity: int16Samples.count * 2)
        for sample in int16Samples {
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }

        var header = Data()
        let dataSize = UInt32(pcmData.count)
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: (dataSize + 36).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var fileData = header
        fileData.append(pcmData)
        try fileData.write(to: url)
    }
}
