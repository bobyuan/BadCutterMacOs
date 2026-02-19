import Foundation

final class FeatureExtractorStub: FeatureExtractor {
    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame] {
        stride(from: 0.0, through: 30.0, by: 0.5).map {
            FeatureFrame(timestamp: $0, motionScore: Double.random(in: 0.1...0.9), audioScore: Double.random(in: 0.1...0.9))
        }
    }
}
