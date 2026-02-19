import XCTest
@testable import BadmintonVideoCutter

final class HybridSegmenterTests: XCTestCase {
    func testClassifierReturnsAtLeastOneSegment() {
        let frames = [
            FeatureFrame(timestamp: 0, motionScore: 0.7, audioScore: 0.5),
            FeatureFrame(timestamp: 1, motionScore: 0.8, audioScore: 0.6)
        ]
        let sut = HybridSegmenter()
        let out = sut.classify(frames: frames, config: AnalysisConfig())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.label, .rally)
    }
}
