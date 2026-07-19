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

    // MARK: - Added-Point Default Span

    /// Default span for a point added at the playhead (DESIGN §3.2): the
    /// surrounding break's high-audio window when one is near the playhead,
    /// else ±4s. Never overlaps the neighboring active points.
    static func defaultAddedPointSpan(
        playhead: TimeInterval,
        frames: [FeatureFrame],
        activeSegments: [TimeSegment],
        videoDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let fallbackHalfSpan: TimeInterval = 4.0
        let minSpan: TimeInterval = 1.0
        let sorted = activeSegments.sorted { $0.start < $1.start }

        // Playhead inside an existing point: no break to fit into, just ±4s.
        if sorted.contains(where: { $0.start <= playhead && playhead <= $0.end }) {
            return (max(0, playhead - fallbackHalfSpan),
                    min(videoDuration, playhead + fallbackHalfSpan))
        }

        let gapStart = sorted.last(where: { $0.end <= playhead })?.end ?? 0
        let gapEnd = sorted.first(where: { $0.start >= playhead })?.start ?? videoDuration

        // Contiguous runs of high-audio frames within the break (audio is
        // quantized; >= 0.5 excludes silence and ambient noise).
        var runs: [(start: TimeInterval, end: TimeInterval)] = []
        for frame in frames where frame.timestamp >= gapStart && frame.timestamp <= gapEnd && frame.audioScore >= 0.5 {
            if let last = runs.last, frame.timestamp - last.end <= 1.0 {
                runs[runs.count - 1].end = frame.timestamp
            } else {
                runs.append((frame.timestamp, frame.timestamp))
            }
        }

        func distance(to run: (start: TimeInterval, end: TimeInterval)) -> TimeInterval {
            if playhead < run.start { return run.start - playhead }
            if playhead > run.end { return playhead - run.end }
            return 0
        }

        var start: TimeInterval
        var end: TimeInterval
        if let run = runs.min(by: { distance(to: $0) < distance(to: $1) }), distance(to: run) <= 3.0 {
            start = run.start - 1.0
            end = run.end + 1.0
        } else {
            start = playhead - fallbackHalfSpan
            end = playhead + fallbackHalfSpan
        }
        start = max(gapStart, max(0, start))
        end = min(gapEnd, min(videoDuration, end))

        // Clamping can leave a sliver — expand back to a workable minimum
        // within the break.
        if end - start < minSpan {
            let mid = (start + end) / 2
            start = max(gapStart, mid - minSpan / 2)
            end = min(gapEnd, start + minSpan)
            start = max(gapStart, end - minSpan)
        }
        return (start, end)
    }
}
