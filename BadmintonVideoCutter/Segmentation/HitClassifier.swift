import Foundation
import AVFoundation
import SoundAnalysis
import CoreML

final class HitClassifier {

    enum ClassifierError: LocalizedError {
        case noAudioTrack
        case modelLoadFailed(String)
        case analysisFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "Video has no audio track."
            case .modelLoadFailed(let msg): return "Failed to load ML model: \(msg)"
            case .analysisFailed(let msg): return "Sound analysis failed: \(msg)"
            }
        }
    }

    static func classify(videoURL: URL, modelURL: URL) async throws -> [AudioFeature] {
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        try await extractAudioToWAV(from: videoURL, to: tempWAV)

        let mlModel: MLModel
        do {
            mlModel = try MLModel(contentsOf: modelURL)
        } catch {
            throw ClassifierError.modelLoadFailed(error.localizedDescription)
        }

        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(mlModel: mlModel)
        } catch {
            throw ClassifierError.modelLoadFailed(error.localizedDescription)
        }
        request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 44100)
        request.overlapFactor = 0.5

        let analyzer = try SNAudioFileAnalyzer(url: tempWAV)
        let observer = ResultsObserver()

        try analyzer.add(request, withObserver: observer)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            observer.onComplete = {
                continuation.resume()
            }
            analyzer.analyze()
        }

        if let error = observer.error {
            throw ClassifierError.analysisFailed(error.localizedDescription)
        }

        return observer.features
    }

    // MARK: - Audio Extraction

    private static func extractAudioToWAV(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ClassifierError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        var allData = Data()
        reader.startReading()
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { continue }
            allData.append(Data(bytes: ptr, count: length))
        }

        writeWAV(pcmData: allData, sampleRate: 44100, channels: 1, bitsPerSample: 16, to: outputURL)
    }

    private static func writeWAV(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int, to url: URL) {
        var header = Data()
        let dataSize = UInt32(pcmData.count)
        let fileSize = dataSize + 36

        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var fileData = header
        fileData.append(pcmData)
        try? fileData.write(to: url)
    }
}

// MARK: - SoundAnalysis Observer

private final class ResultsObserver: NSObject, SNResultsObserving {
    var features: [AudioFeature] = []
    var error: Error?
    var onComplete: (() -> Void)?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let timeRange = classification.timeRange
        let timestamp = timeRange.start.seconds + timeRange.duration.seconds / 2.0

        let rallyConfidence = classification.classification(forIdentifier: "rally")?.confidence ?? 0
        features.append(AudioFeature(
            timestamp: timestamp,
            rmsEnergy: 0,
            isOnset: false,
            rallyScore: Double(rallyConfidence)
        ))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        self.error = error
        onComplete?()
    }

    func requestDidComplete(_ request: SNRequest) {
        onComplete?()
    }
}
