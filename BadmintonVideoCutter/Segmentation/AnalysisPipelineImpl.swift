import Foundation

final class AnalysisPipelineImpl: AnalysisPipeline {
    private let extractor: FeatureExtractor
    private let classifier: SegmentClassifier
    private let postProcessor: SegmentPostProcessor

    init(extractor: FeatureExtractor, classifier: SegmentClassifier, postProcessor: SegmentPostProcessor) {
        self.extractor = extractor
        self.classifier = classifier
        self.postProcessor = postProcessor
    }

    func analyze(videoURL: URL, config: AnalysisConfig) async throws -> [TimeSegment] {
        let frames = try await extractor.extractFeatures(from: videoURL)
        let segments = classifier.classify(frames: frames, config: config)
        return postProcessor.postProcess(segments: segments, frames: frames, config: config)
    }
}
