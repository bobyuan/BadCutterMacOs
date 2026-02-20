import Foundation

final class HybridSegmenter: SegmentClassifier, SegmentPostProcessor {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard frames.count > 1 else { return [] }

        let mw = config.motionWeight
        let aw = config.audioWeight
        let totalWeight = mw + aw
        let normalizedMotionWeight = totalWeight > 0 ? mw / totalWeight : 0.5
        let normalizedAudioWeight = totalWeight > 0 ? aw / totalWeight : 0.5

        // Hybrid scoring: blend additive + multiplicative.
        // Additive: catches rallies where one signal dominates (e.g., short 1-2 hit
        //   rallies that have high motion but no audio cluster).
        // Multiplicative: suppresses cases where only one signal is high
        //   (e.g., casual hit during bird pickup = high audio, low motion).
        // 70/30 blend ensures motion-only frames (short rallies) still get decent scores
        // rather than being vetoed by zero audio.
        let combinedScores = frames.map { frame in
            let additive = normalizedMotionWeight * frame.motionScore + normalizedAudioWeight * frame.audioScore
            let multiplicative = sqrt(frame.motionScore * frame.audioScore)
            return 0.7 * additive + 0.3 * multiplicative
        }

        let threshold = percentile(combinedScores, p: config.rallyPercentile)
        let labels = combinedScores.map { $0 >= threshold ? SegmentLabel.rally : SegmentLabel.betweenPoints }

        var segments: [TimeSegment] = []
        var currentLabel: SegmentLabel = labels[0]
        var start = frames[0].timestamp
        var confidences: [Double] = []

        for i in 1..<frames.count {
            let score = combinedScores[i]
            let label = labels[i]
            confidences.append(score)

            if label != currentLabel {
                let conf = confidence(confidences)
                segments.append(TimeSegment(start: start, end: frames[i].timestamp, label: currentLabel, confidence: conf))
                start = frames[i].timestamp
                currentLabel = label
                confidences = []
            }
        }

        if let last = frames.last {
            segments.append(TimeSegment(start: start, end: last.timestamp, label: currentLabel, confidence: confidence(confidences)))
        }

        return segments
    }

    func postProcess(segments: [TimeSegment], frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        let valid = SegmentUtils.removeInvalid(segments)
        let merged = SegmentUtils.mergeAdjacent(valid, maxGap: config.flipHysteresisSeconds)
        let filtered = merged.filter {
            if $0.label == .rally { return $0.duration >= config.minRallyDuration }
            if $0.label == .betweenPoints { return $0.duration >= config.minBetweenPointsDuration }
            return true
        }
        let preRolled = applyPreRoll(segments: filtered, preRoll: config.preRollSeconds)
        return splitLongRallies(segments: preRolled, frames: frames, config: config)
    }

    // MARK: - Rally Splitting

    /// Splits rally segments longer than `maxExpectedRallyDuration` at internal
    /// activity dips, which indicate between-point pauses that were missed.
    private func splitLongRallies(segments: [TimeSegment], frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard !frames.isEmpty else { return segments }

        let mw = config.motionWeight
        let aw = config.audioWeight
        let totalWeight = mw + aw
        let normalizedMotionWeight = totalWeight > 0 ? mw / totalWeight : 0.5
        let normalizedAudioWeight = totalWeight > 0 ? aw / totalWeight : 0.5

        // Compute classification threshold (same as classify)
        let allScores = frames.map { frame -> Double in
            let additive = normalizedMotionWeight * frame.motionScore + normalizedAudioWeight * frame.audioScore
            let multiplicative = sqrt(frame.motionScore * frame.audioScore)
            return 0.7 * additive + 0.3 * multiplicative
        }
        let classificationThreshold = percentile(allScores, p: config.rallyPercentile)
        let dipScoreThreshold = classificationThreshold * 0.7

        var result: [TimeSegment] = []

        for segment in segments {
            guard segment.label == .rally && segment.duration > config.maxExpectedRallyDuration else {
                result.append(segment)
                continue
            }

            // Get frames within this rally
            let rallyFrames = frames.filter { $0.timestamp >= segment.start && $0.timestamp <= segment.end }
            guard rallyFrames.count >= 5 else {
                result.append(segment)
                continue
            }

            // Compute combined scores for these frames
            let scores = rallyFrames.map { frame -> Double in
                let additive = normalizedMotionWeight * frame.motionScore + normalizedAudioWeight * frame.audioScore
                let multiplicative = sqrt(frame.motionScore * frame.audioScore)
                return 0.7 * additive + 0.3 * multiplicative
            }

            // Smooth with rolling average (window ~1s = 5 frames at 200ms)
            let smoothed = rollingAverage(scores, windowSize: 5)

            // Find dip regions: contiguous frames below dipScoreThreshold
            let dips = findDips(
                frames: rallyFrames,
                smoothedScores: smoothed,
                threshold: dipScoreThreshold,
                minDuration: config.minDipDuration
            )

            if dips.isEmpty {
                result.append(segment)
                continue
            }

            // Split the rally at each dip
            let subSegments = splitAtDips(segment: segment, dips: dips, minRallyDuration: config.minRallyDuration)
            result.append(contentsOf: subSegments)
        }

        return result
    }

    private func rollingAverage(_ values: [Double], windowSize: Int) -> [Double] {
        guard values.count >= windowSize else { return values }
        let halfW = windowSize / 2
        return values.indices.map { i in
            let lo = max(0, i - halfW)
            let hi = min(values.count - 1, i + halfW)
            let window = values[lo...hi]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    private struct Dip {
        var start: TimeInterval
        var end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    private func findDips(frames: [FeatureFrame], smoothedScores: [Double], threshold: Double, minDuration: TimeInterval) -> [Dip] {
        var dips: [Dip] = []
        var dipStart: TimeInterval?

        for (i, score) in smoothedScores.enumerated() {
            if score < threshold {
                if dipStart == nil {
                    dipStart = frames[i].timestamp
                }
            } else {
                if let start = dipStart {
                    let end = frames[i].timestamp
                    if end - start >= minDuration {
                        dips.append(Dip(start: start, end: end))
                    }
                    dipStart = nil
                }
            }
        }

        // Handle dip extending to end of segment
        if let start = dipStart, let lastFrame = frames.last {
            let end = lastFrame.timestamp
            if end - start >= minDuration {
                dips.append(Dip(start: start, end: end))
            }
        }

        return dips
    }

    private func splitAtDips(segment: TimeSegment, dips: [Dip], minRallyDuration: TimeInterval) -> [TimeSegment] {
        var result: [TimeSegment] = []
        var currentStart = segment.start

        for dip in dips {
            // Rally before the dip
            if dip.start - currentStart >= minRallyDuration {
                result.append(TimeSegment(
                    start: currentStart,
                    end: dip.start,
                    label: .rally,
                    confidence: segment.confidence
                ))
            }

            // The dip itself becomes a betweenPoints segment
            result.append(TimeSegment(
                start: dip.start,
                end: dip.end,
                label: .betweenPoints,
                confidence: 0.3
            ))

            currentStart = dip.end
        }

        // Rally after the last dip
        if segment.end - currentStart >= minRallyDuration {
            result.append(TimeSegment(
                start: currentStart,
                end: segment.end,
                label: .rally,
                confidence: segment.confidence
            ))
        }

        // If splitting produced nothing useful, keep original
        if result.filter({ $0.label == .rally }).isEmpty {
            return [segment]
        }

        return result
    }

    // MARK: - Pre-Roll

    /// Extends each rally segment's start backward by `preRoll` seconds
    /// to capture serve preparation. Shrinks preceding between-points segments
    /// accordingly and removes any that become too short.
    private func applyPreRoll(segments: [TimeSegment], preRoll: TimeInterval) -> [TimeSegment] {
        guard preRoll > 0, !segments.isEmpty else { return segments }

        var result = segments
        for i in 0..<result.count {
            guard result[i].label == .rally else { continue }

            // Don't push start before the previous rally's end
            let floor: TimeInterval
            if i > 0 && result[i - 1].label == .rally {
                floor = result[i - 1].end
            } else {
                floor = 0
            }

            let newStart = max(floor, result[i].start - preRoll)
            let stolen = result[i].start - newStart
            result[i].start = newStart

            // Shrink the preceding between-points segment if it exists
            if i > 0 && result[i - 1].label == .betweenPoints {
                result[i - 1].end -= stolen
            }
        }

        // Remove between-points segments that shrank below 1.0s
        let filtered = result.filter {
            if $0.label == .betweenPoints { return $0.duration >= 1.0 }
            return $0.duration > 0
        }

        // Merge consecutive rally segments that became adjacent after removing gaps
        guard !filtered.isEmpty else { return filtered }
        var merged: [TimeSegment] = [filtered[0]]
        for seg in filtered.dropFirst() {
            if seg.label == .rally && merged.last!.label == .rally {
                merged[merged.count - 1].end = seg.end
                merged[merged.count - 1].confidence = max(merged[merged.count - 1].confidence, seg.confidence)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    // MARK: - Helpers

    private func confidence(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        return min(max(values.reduce(0, +) / Double(values.count), 0.05), 0.99)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pp = max(0, min(1, p))
        let idx = Int(Double(sorted.count - 1) * pp)
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
