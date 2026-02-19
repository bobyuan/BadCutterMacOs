import Foundation

protocol FeatureExtractor {
    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame]
}

protocol SegmentClassifier {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment]
}

protocol SegmentPostProcessor {
    func postProcess(segments: [TimeSegment], config: AnalysisConfig) -> [TimeSegment]
}

protocol AnalysisPipeline {
    func analyze(videoURL: URL, config: AnalysisConfig) async throws -> [TimeSegment]
}

struct FeatureFrame: Sendable {
    var timestamp: TimeInterval
    var motionScore: Double
    var audioScore: Double
}
