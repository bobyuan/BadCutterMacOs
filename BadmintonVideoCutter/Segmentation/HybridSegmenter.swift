import Foundation

final class HybridSegmenter: SegmentClassifier, SegmentPostProcessor {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard frames.count > 1 else { return [] }

        let mw = config.motionWeight
        let aw = config.audioWeight
        let totalWeight = mw + aw
        let normalizedMotionWeight = totalWeight > 0 ? mw / totalWeight : 0.5
        let normalizedAudioWeight = totalWeight > 0 ? aw / totalWeight : 0.5

        let combinedScores = frames.map { frame in
            normalizedMotionWeight * frame.motionScore + normalizedAudioWeight * frame.audioScore
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

    func postProcess(segments: [TimeSegment], config: AnalysisConfig) -> [TimeSegment] {
        let valid = SegmentUtils.removeInvalid(segments)
        let merged = SegmentUtils.mergeAdjacent(valid, maxGap: config.flipHysteresisSeconds)
        let filtered = merged.filter {
            if $0.label == .rally { return $0.duration >= config.minRallyDuration }
            if $0.label == .betweenPoints { return $0.duration >= config.minBetweenPointsDuration }
            return true
        }
        return applyPreRoll(segments: filtered, preRoll: config.preRollSeconds)
    }

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

        // Remove between-points segments that shrank below 0.5s
        let filtered = result.filter {
            if $0.label == .betweenPoints { return $0.duration >= 0.5 }
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
