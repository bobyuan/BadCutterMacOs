import XCTest
@testable import BadmintonVideoCutter

final class SegmentUtilsTests: XCTestCase {
    func testMergeAdjacentSameLabel() {
        let s1 = TimeSegment(start: 0, end: 2, label: .rally, confidence: 0.8)
        let s2 = TimeSegment(start: 2.05, end: 4, label: .rally, confidence: 0.9)
        let merged = SegmentUtils.mergeAdjacent([s1, s2], maxGap: 0.1)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(merged[0].end, 4, accuracy: 0.001)
    }
}
