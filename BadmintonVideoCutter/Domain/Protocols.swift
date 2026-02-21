import Foundation

protocol FeatureExtractor {
    func extractFeatures(from videoURL: URL) async throws -> [FeatureFrame]
}

protocol SegmentClassifier {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment]
}

protocol SegmentPostProcessor {
    func postProcess(segments: [TimeSegment], frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment]
}

protocol AnalysisPipeline {
    func analyze(videoURL: URL, config: AnalysisConfig) async throws -> [TimeSegment]
}

struct FeatureFrame: Sendable {
    var timestamp: TimeInterval
    var motionScore: Double
    var audioScore: Double
    /// Shuttlecock in-flight confidence (0 = not detected, 1 = fast flight confirmed).
    /// Based on velocity-tracked blob detection across consecutive frames.
    var shuttlecockFlightScore: Double = 0
}
