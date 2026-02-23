import Foundation

struct TrajectoryAnalyzer {

    /// Refine rally segments by detecting point boundaries from shuttle trajectory gaps.
    /// Runs as a post-processing step after HybridSegmenter.postProcess.
    /// Falls back gracefully when ML shuttle data is unavailable.
    static func refineSegments(
        segments: [TimeSegment],
        frames: [FeatureFrame],
        config: AnalysisConfig
    ) -> [TimeSegment] {
        guard !segments.isEmpty, !frames.isEmpty else { return segments }

        var result: [TimeSegment] = []

        for segment in segments {
            guard segment.label == .rally else {
                result.append(segment)
                continue
            }

            let rallyFrames = frames.filter { $0.timestamp >= segment.start && $0.timestamp <= segment.end }

            // Phase 1: Pre-filter — check shuttle detection rate
            let detectionCount = rallyFrames.filter { $0.shuttlecockFlightScore > 0 }.count
            let detectionRate = rallyFrames.isEmpty ? 0 : Double(detectionCount) / Double(rallyFrames.count)

            if detectionRate < 0.10 {
                // ML model wasn't used or very few detections — keep segment as-is
                result.append(segment)
                continue
            }

            // Phase 2: Gap Detection
            let gaps = detectGaps(in: rallyFrames, config: config)

            if gaps.isEmpty {
                result.append(segment)
                continue
            }

            // Phase 3: Gap Validation
            let validGaps = gaps.filter { gap in
                let score = validateGap(gap, frames: rallyFrames, config: config)
                return score >= config.minGapValidationScore
            }

            if validGaps.isEmpty {
                result.append(segment)
                continue
            }

            // Phase 4: Split
            let subSegments = splitAtGaps(
                segment: segment,
                gaps: validGaps,
                config: config
            )
            result.append(contentsOf: subSegments)
        }

        return result
    }

    // MARK: - Phase 2: Gap Detection

    private struct ShuttleGap {
        var start: TimeInterval
        var end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// Scan frames for periods where shuttlecockFlightScore stays below threshold.
    private static func detectGaps(
        in frames: [FeatureFrame],
        config: AnalysisConfig
    ) -> [ShuttleGap] {
        var gaps: [ShuttleGap] = []
        var gapStart: TimeInterval?

        for frame in frames {
            if frame.shuttlecockFlightScore < config.shuttleGapThreshold {
                if gapStart == nil {
                    gapStart = frame.timestamp
                }
            } else {
                if let start = gapStart {
                    let duration = frame.timestamp - start
                    if duration >= config.minShuttleGap && duration <= config.maxShuttleGap {
                        gaps.append(ShuttleGap(start: start, end: frame.timestamp))
                    }
                    gapStart = nil
                }
            }
        }

        // Handle gap extending to end of frames
        if let start = gapStart, let lastFrame = frames.last {
            let duration = lastFrame.timestamp - start
            if duration >= config.minShuttleGap && duration <= config.maxShuttleGap {
                gaps.append(ShuttleGap(start: start, end: lastFrame.timestamp))
            }
        }

        return gaps
    }

    // MARK: - Phase 3: Gap Validation

    /// Score a candidate gap from 0-3 based on confirmation signals.
    private static func validateGap(
        _ gap: ShuttleGap,
        frames: [FeatureFrame],
        config: AnalysisConfig
    ) -> Int {
        var score = 0

        let gapFrames = frames.filter { $0.timestamp >= gap.start && $0.timestamp <= gap.end }

        // Signal 1: Motion dip — players pause between points
        if !gapFrames.isEmpty {
            let avgMotion = gapFrames.reduce(0.0) { $0 + $1.motionScore } / Double(gapFrames.count)
            if avgMotion < 0.3 {
                score += 1
            }
        }

        // Signal 2: Position discontinuity — shuttle reappears at different location
        let beforeFrames = frames.filter {
            $0.timestamp < gap.start && $0.shuttlecockPosition != nil
        }
        let afterFrames = frames.filter {
            $0.timestamp > gap.end && $0.shuttlecockPosition != nil
        }

        if let lastBefore = beforeFrames.last?.shuttlecockPosition,
           let firstAfter = afterFrames.first?.shuttlecockPosition {
            let dx = lastBefore.x - firstAfter.x
            let dy = lastBefore.y - firstAfter.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance > config.positionDiscontinuityThreshold {
                score += 1
            }
        }

        // Signal 3: Confidence pattern — clean disappearance/reappearance
        let lastBeforeFrame = frames.last { $0.timestamp < gap.start }
        let firstAfterFrame = frames.first { $0.timestamp > gap.end }

        if let before = lastBeforeFrame, let after = firstAfterFrame {
            if before.shuttlecockFlightScore > 0.5 && after.shuttlecockFlightScore > 0.5 {
                score += 1
            }
        }

        return score
    }

    // MARK: - Phase 4: Split

    /// Split a rally segment at validated gaps, inserting betweenPoints segments.
    private static func splitAtGaps(
        segment: TimeSegment,
        gaps: [ShuttleGap],
        config: AnalysisConfig
    ) -> [TimeSegment] {
        let sortedGaps = gaps.sorted { $0.start < $1.start }
        var result: [TimeSegment] = []
        var currentStart = segment.start

        for gap in sortedGaps {
            // Rally sub-segment before the gap (with post-roll trimmed into gap)
            let rallyEnd = gap.start + config.postRollSeconds
            let clampedRallyEnd = min(rallyEnd, gap.end)

            if clampedRallyEnd - currentStart >= config.minRallyDuration {
                result.append(TimeSegment(
                    start: currentStart,
                    end: clampedRallyEnd,
                    label: .rally,
                    confidence: segment.confidence
                ))
            }

            // Between-points gap
            result.append(TimeSegment(
                start: clampedRallyEnd,
                end: gap.end,
                label: .betweenPoints,
                confidence: 0.3
            ))

            // Next rally starts with pre-roll before gap ends
            let nextStart = max(gap.end - config.preRollSeconds, gap.end)
            currentStart = nextStart
        }

        // Remaining rally after last gap
        if segment.end - currentStart >= config.minRallyDuration {
            result.append(TimeSegment(
                start: currentStart,
                end: segment.end,
                label: .rally,
                confidence: segment.confidence
            ))
        }

        // If splitting produced no rallies, keep original
        if result.filter({ $0.label == .rally }).isEmpty {
            return [segment]
        }

        return result
    }
}
