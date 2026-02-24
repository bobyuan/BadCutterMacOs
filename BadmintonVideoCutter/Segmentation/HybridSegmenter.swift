import Foundation

final class HybridSegmenter: SegmentClassifier, SegmentPostProcessor {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard frames.count > 1 else { return [] }

        let shuttlePrimary = useShuttlePrimary(frames: frames)
        let combinedScores = computeCombinedScores(frames: frames, shuttlePrimary: shuttlePrimary, config: config)

        // Shuttle-primary: fixed threshold (displacement-based signal is bimodal)
        // Fallback: adaptive percentile for the continuous motion score distribution
        // Shuttle mode: position-presence combined score is bimodal
        //   rally center ≈ 0.55-0.65, break center ≈ 0.20-0.30
        let threshold = shuttlePrimary ? 0.38 : percentile(combinedScores, p: config.rallyPercentile)
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
        let shuttlePrimary = useShuttlePrimary(frames: frames)
        let valid = SegmentUtils.removeInvalid(segments)

        // Shuttle-primary: tighter merge gap — the shuttle position signal is precise,
        // so don't over-merge. Fallback: original hysteresis for noisy motion signal.
        let mergeGap = shuttlePrimary ? 0.5 : config.flipHysteresisSeconds
        let merged = SegmentUtils.mergeAdjacent(valid, maxGap: mergeGap)

        // Shuttle-primary: shorter min break — shuttle absence gaps are brief (2-3s)
        // even though the actual between-point pause is longer.
        let minBreak = shuttlePrimary ? 1.5 : config.minBetweenPointsDuration
        let filtered = merged.filter {
            if $0.label == .rally { return $0.duration >= config.minRallyDuration }
            if $0.label == .betweenPoints { return $0.duration >= minBreak }
            return true
        }

        // Shuttle-primary: minimal pre/post roll — shuttle position signal already
        // captures rally boundaries precisely (shuttle appears at serve, disappears
        // at point end). Large pre/post roll (2.5+1.5=4.0s) would consume real breaks
        // that are only 2-4s long. Fallback: original generous pre/post roll for the
        // noisy motion signal which may start/end classification late.
        let preRoll = shuttlePrimary ? 0.5 : config.preRollSeconds
        let postRoll = shuttlePrimary ? 0.5 : config.postRollSeconds
        let preRolled = applyPreRoll(segments: filtered, preRoll: preRoll)
        let postRolled = applyPostRoll(segments: preRolled, postRoll: postRoll)
        let split = splitLongRallies(segments: postRolled, frames: frames, config: config)

        // Final cleanup: remove 0-duration segments, merge consecutive same-label
        // (splitLongRallies can produce consecutive breaks when short rally remnants
        // are dropped between two dip-breaks)
        let cleaned = SegmentUtils.removeInvalid(split)
        return SegmentUtils.mergeAdjacent(cleaned, maxGap: 0)
    }

    // MARK: - Combined Score Computation

    /// Computes per-frame combined scores. When ML shuttle position data is available,
    /// uses shuttle displacement velocity (is the shuttle *moving*?) as the ML signal.
    /// Shuttle detected but stationary = break. Shuttle moving across court = rally.
    /// Falls back to original motion+audio formula when no ML data.
    private func computeCombinedScores(frames: [FeatureFrame], shuttlePrimary: Bool, config: AnalysisConfig) -> [Double] {
        if shuttlePrimary {
            // Use shuttle position gaps as the primary signal.
            // During breaks, shuttle has no position for extended stretches.
            // During rallies, positions are present most frames.
            // Blend: position presence rate (60%) + motion (30%) + audio (10%)
            let presenceScores = computeShuttlePresenceScores(frames: frames)
            return frames.indices.map { i in
                min(0.60 * presenceScores[i] + 0.30 * frames[i].motionScore + 0.10 * frames[i].audioScore, 1.0)
            }
        } else {
            // Fallback: original motion + audio bonus (no ML data)
            let audioBonus = config.audioWeight
            return frames.map { frame in
                min(frame.motionScore + audioBonus * frame.audioScore, 1.0)
            }
        }
    }

    /// Computes per-frame shuttle "presence" score using a rolling window.
    /// Key insight: during breaks, shuttle has NO position for extended stretches
    /// (shuttle picked up, not visible). During rallies, positions are present
    /// in most frames. Using a wide window (~4s) ensures brief detection gaps
    /// during rallies are bridged, while sustained absence during breaks (>2s)
    /// drops the score significantly.
    private func computeShuttlePresenceScores(frames: [FeatureFrame]) -> [Double] {
        let presence = frames.map { $0.shuttlecockPosition != nil ? 1.0 : 0.0 }

        // Wide rolling window: ~4s = 20 frames at 200ms.
        // Breaks typically show 10-15+ consecutive no-position frames (~2-3s).
        // A 20-frame window captures this: break center → presence ≈ 0.3-0.5.
        // Rally: mostly positions present → presence ≈ 0.7-0.9.
        let windowSize = 20
        let halfW = windowSize / 2
        return frames.indices.map { i in
            let lo = max(0, i - halfW)
            let hi = min(frames.count - 1, i + halfW)
            let window = presence[lo...hi]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    /// Returns true when ML shuttle position data is meaningfully present.
    /// Requires >10% of frames to have position data (ML model was active).
    private func useShuttlePrimary(frames: [FeatureFrame]) -> Bool {
        guard !frames.isEmpty else { return false }
        let positionCount = frames.filter { $0.shuttlecockPosition != nil }.count
        let positionRate = Double(positionCount) / Double(frames.count)
        return positionRate > 0.10
    }

    // MARK: - Rally Splitting

    /// Splits rally segments longer than `maxExpectedRallyDuration` at internal
    /// activity dips, which indicate between-point pauses that were missed.
    private func splitLongRallies(segments: [TimeSegment], frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard !frames.isEmpty else { return segments }

        let shuttlePrimary = useShuttlePrimary(frames: frames)

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

            let scores: [Double]
            let dipThreshold: Double
            let minDipDur: TimeInterval

            if shuttlePrimary {
                // Shuttle-primary: use motion score for dip detection.
                // The shuttle may remain visible during breaks, but player motion
                // clearly drops (0.05-0.08 break vs 0.10-0.25 rally).
                scores = rallyFrames.map(\.motionScore)
                dipThreshold = 0.09
                minDipDur = 1.5
            } else {
                let allScores = computeCombinedScores(frames: frames, shuttlePrimary: false, config: config)
                let classificationThreshold = percentile(allScores, p: config.rallyPercentile)
                scores = computeCombinedScores(frames: rallyFrames, shuttlePrimary: false, config: config)
                dipThreshold = classificationThreshold * 0.7
                minDipDur = config.minDipDuration
            }

            // Smooth with rolling average (window ~1s = 5 frames at 200ms)
            let smoothed = rollingAverage(scores, windowSize: 5)

            // Find dip regions: contiguous frames below dipScoreThreshold
            let dips = findDips(
                frames: rallyFrames,
                smoothedScores: smoothed,
                threshold: dipThreshold,
                minDuration: minDipDur
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

    // MARK: - Post-Roll

    /// Extends each rally segment's end forward by `postRoll` seconds
    /// to capture the birdie landing after the last hit. In badminton,
    /// a player may stop moving 1-3 seconds before the point actually ends
    /// (they know they can't reach the bird). Post-roll prevents cutting
    /// the point short.
    private func applyPostRoll(segments: [TimeSegment], postRoll: TimeInterval) -> [TimeSegment] {
        guard postRoll > 0, !segments.isEmpty else { return segments }

        var result = segments
        for i in 0..<result.count {
            guard result[i].label == .rally else { continue }

            // Don't push end past the next rally's start
            let ceiling: TimeInterval
            if i + 1 < result.count && result[i + 1].label == .rally {
                ceiling = result[i + 1].start
            } else {
                ceiling = .greatestFiniteMagnitude
            }

            let newEnd = min(ceiling, result[i].end + postRoll)
            let stolen = newEnd - result[i].end
            result[i].end = newEnd

            // Shrink the following between-points segment if it exists
            if i + 1 < result.count && result[i + 1].label == .betweenPoints {
                result[i + 1].start += stolen
            }
        }

        // Remove between-points segments that shrank below 1.0s
        let filtered = result.filter {
            if $0.label == .betweenPoints { return $0.duration >= 1.0 }
            return $0.duration > 0
        }

        // Merge consecutive rally segments that became adjacent
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
