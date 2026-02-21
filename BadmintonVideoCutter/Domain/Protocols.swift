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
    /// Based on arrived/departed cluster displacement within frame pairs.
    var shuttlecockFlightScore: Double = 0
    /// Detected shuttlecock position in normalized coordinates (0-1).
    /// nil when no shuttlecock detected. Based on the "arrived" cluster centroid
    /// (where new white pixels appeared = shuttlecock's current position).
    var shuttlecockPosition: (x: Double, y: Double)? = nil
}
