import Foundation

enum SegmentUtils {
    static func mergeAdjacent(_ segments: [TimeSegment], maxGap: TimeInterval = 0.15) -> [TimeSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [TimeSegment] = [sorted[0]]

        for current in sorted.dropFirst() {
            guard var last = merged.last else { continue }
            if current.label == last.label && current.start - last.end <= maxGap {
                last.end = max(last.end, current.end)
                last.confidence = max(last.confidence, current.confidence)
                merged[merged.count - 1] = last
            } else {
                merged.append(current)
            }
        }
        return merged
    }

    static func removeInvalid(_ segments: [TimeSegment]) -> [TimeSegment] {
        segments.filter { $0.end > $0.start }
    }
}
