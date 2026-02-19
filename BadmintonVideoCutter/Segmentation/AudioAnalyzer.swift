import Foundation
import AVFoundation
import Accelerate

final class AudioAnalyzer: Sendable {

    struct Config {
        var windowSize: Int = 2048
        var hopSize: Int = 1024
        var rallyWindowSeconds: TimeInterval = 2.0
        var onsetThresholdMultiplier: Double = 1.5
        var medianWindowSize: Int = 15
        var lowFreqBin: Int = 2    // ~1 kHz at 44.1kHz / 2048
        var highFreqBin: Int = 186 // ~8 kHz at 44.1kHz / 2048
        // Minimum flux magnitude to count as an onset (filters footsteps/talking).
        // Expressed as fraction of normalized flux [0,1]. Onsets below this are ignored.
        var onsetIntensityFloor: Double = 0.15
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func analyzeAudio(from videoURL: URL, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [AudioFeature] {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }

        onProgress?(0.1)
        let pcmData = try await readPCMAudio(asset: asset, track: audioTrack)
        guard !pcmData.samples.isEmpty else { return [] }
        onProgress?(0.4)

        let rmsValues = computeRMS(samples: pcmData.samples, sampleRate: pcmData.sampleRate)
        onProgress?(0.6)
        let spectralFlux = computeSpectralFlux(samples: pcmData.samples, sampleRate: pcmData.sampleRate)
        onProgress?(0.8)
        let onsets = detectOnsets(spectralFlux: spectralFlux)
        let rallyScores = computeRallyScores(
            onsets: onsets,
            totalFrames: rmsValues.count,
            sampleRate: pcmData.sampleRate
        )
        onProgress?(0.95)

        var features: [AudioFeature] = []
        for i in 0..<rmsValues.count {
            let timestamp = Double(i * config.hopSize) / pcmData.sampleRate
            features.append(AudioFeature(
                timestamp: timestamp,
                rmsEnergy: rmsValues[i],
                isOnset: onsets[i],
                rallyScore: i < rallyScores.count ? rallyScores[i] : 0
            ))
        }

        onProgress?(1.0)
        return features
    }

    // MARK: - PCM Reading

    private struct PCMData {
        var samples: [Float]
        var sampleRate: Double
    }

    private func readPCMAudio(asset: AVAsset, track: AVAssetTrack) async throws -> PCMData {
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

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        var allSamples: [Float] = []
        let sampleRate: Double = 44100.0

        reader.startReading()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        return PCMData(samples: allSamples, sampleRate: sampleRate)
    }

    // MARK: - RMS Energy

    private func computeRMS(samples: [Float], sampleRate: Double) -> [Double] {
        let windowSize = config.windowSize
        let hopSize = config.hopSize
        var rmsValues: [Double] = []

        var offset = 0
        while offset + windowSize <= samples.count {
            var sumOfSquares: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_svesq(buffer.baseAddress! + offset, 1, &sumOfSquares, vDSP_Length(windowSize))
            }
            let rms = sqrt(Double(sumOfSquares) / Double(windowSize))
            rmsValues.append(rms)
            offset += hopSize
        }

        return rmsValues
    }

    // MARK: - Spectral Flux

    private func computeSpectralFlux(samples: [Float], sampleRate: Double) -> [Double] {
        let windowSize = config.windowSize
        let hopSize = config.hopSize
        let log2n = vDSP_Length(log2(Double(windowSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfSize = windowSize / 2
        var fluxValues: [Double] = []
        var previousMagnitudes = [Float](repeating: 0, count: halfSize)

        var windowFunction = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&windowFunction, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var offset = 0
        while offset + windowSize <= samples.count {
            var windowedSamples = [Float](repeating: 0, count: windowSize)
            for i in 0..<windowSize {
                windowedSamples[i] = samples[offset + i] * windowFunction[i]
            }

            var realPart = [Float](repeating: 0, count: halfSize)
            var imagPart = [Float](repeating: 0, count: halfSize)

            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                    windowedSamples.withUnsafeBufferPointer { sampleBuf in
                        sampleBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            var magnitudes = [Float](repeating: 0, count: halfSize)
            for i in 0..<halfSize {
                magnitudes[i] = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
            }

            // Band-pass: only consider bins in the 1-8 kHz range
            let lowBin = min(config.lowFreqBin, halfSize - 1)
            let highBin = min(config.highFreqBin, halfSize - 1)

            var flux: Float = 0
            for i in lowBin...highBin {
                let diff = magnitudes[i] - previousMagnitudes[i]
                if diff > 0 {
                    flux += diff
                }
            }

            fluxValues.append(Double(flux))
            previousMagnitudes = magnitudes
            offset += hopSize
        }

        // Normalize flux values
        if let maxFlux = fluxValues.max(), maxFlux > 0 {
            fluxValues = fluxValues.map { $0 / maxFlux }
        }

        return fluxValues
    }

    // MARK: - Onset Detection

    private func detectOnsets(spectralFlux: [Double]) -> [Bool] {
        guard !spectralFlux.isEmpty else { return [] }

        let medianW = config.medianWindowSize
        let multiplier = config.onsetThresholdMultiplier
        let intensityFloor = config.onsetIntensityFloor
        var onsets = [Bool](repeating: false, count: spectralFlux.count)

        for i in 0..<spectralFlux.count {
            let start = max(0, i - medianW / 2)
            let end = min(spectralFlux.count, i + medianW / 2 + 1)
            let window = Array(spectralFlux[start..<end]).sorted()
            let median = window[window.count / 2]
            let threshold = median * multiplier + 0.01

            // Must exceed both the adaptive threshold AND the absolute intensity floor.
            // This filters out weak transients from footsteps, talking, bird pickup etc.
            onsets[i] = spectralFlux[i] > threshold && spectralFlux[i] >= intensityFloor
        }

        return onsets
    }

    // MARK: - Rally Score

    private func computeRallyScores(onsets: [Bool], totalFrames: Int, sampleRate: Double) -> [Double] {
        guard !onsets.isEmpty else { return [] }

        let framesPerRallyWindow = Int(config.rallyWindowSeconds * sampleRate / Double(config.hopSize))
        var scores = [Double](repeating: 0, count: onsets.count)

        for i in 0..<onsets.count {
            let start = max(0, i - framesPerRallyWindow / 2)
            let end = min(onsets.count, i + framesPerRallyWindow / 2 + 1)
            let windowSize = end - start
            guard windowSize > 0 else { continue }

            var onsetCount = 0
            for j in start..<end {
                if onsets[j] { onsetCount += 1 }
            }
            scores[i] = Double(onsetCount) / Double(windowSize)
        }

        // Normalize to [0, 1]
        if let maxScore = scores.max(), maxScore > 0 {
            scores = scores.map { min($0 / maxScore, 1.0) }
        }

        return scores
    }
}
