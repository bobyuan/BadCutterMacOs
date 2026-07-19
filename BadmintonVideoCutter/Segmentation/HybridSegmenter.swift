import Foundation

final class HybridSegmenter: SegmentClassifier, SegmentPostProcessor {
    func classify(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard frames.count > 1 else { return [] }

        let shuttlePrimary = useShuttlePrimary(frames: frames, config: config)
        let combinedScores = computeCombinedScores(frames: frames, shuttlePrimary: shuttlePrimary, config: config)

        // Shuttle-primary: Otsu's method finds optimal binary split for the bimodal
        // score distribution. Adapts per-video (e.g. ~0.37 for both IMG_8510 and IMG_6156).
        // Clamped to prevent pathological edge cases.
        // Fallback: adaptive percentile for the continuous motion score distribution.
        let threshold = shuttlePrimary
            ? otsuThreshold(combinedScores, min: config.shuttleOtsuClampMin, max: config.shuttleOtsuClampMax)
            : percentile(combinedScores, p: config.rallyPercentile)
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
        let shuttlePrimary = useShuttlePrimary(frames: frames, config: config)
        let valid = SegmentUtils.removeInvalid(segments)

        // Shuttle-primary: tighter merge gap — the shuttle position signal is precise,
        // so don't over-merge. Fallback: original hysteresis for noisy motion signal.
        let mergeGap = shuttlePrimary ? config.shuttleMergeGap : config.flipHysteresisSeconds
        let merged = SegmentUtils.mergeAdjacent(valid, maxGap: mergeGap)

        // Shuttle-primary: shorter min break — shuttle absence gaps are brief (2-3s)
        // even though the actual between-point pause is longer.
        let minBreak = shuttlePrimary ? config.shuttleMinBreak : config.minBetweenPointsDuration
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
        let preRoll = shuttlePrimary ? config.shuttlePreRollSeconds : config.preRollSeconds
        let postRoll = shuttlePrimary ? config.shuttlePostRollSeconds : config.postRollSeconds
        let preRolled = applyPreRoll(segments: filtered, preRoll: preRoll)
        let postRolled = applyPostRoll(segments: preRolled, postRoll: postRoll)
        // Iterative splitting: first pass may produce sub-rallies still over maxDuration.
        // Re-run up to 5 times until no further splits occur.
        var split = postRolled
        for _ in 0..<5 {
            let next = splitLongRallies(segments: split, frames: frames, config: config)
            if next.count == split.count { break }
            split = next
        }

        // Final cleanup: absorb tiny rally/break fragments, merge consecutive same-label.
        // Shuttle-primary: aggressive dip splitting creates short rally fragments (1-3s)
        // from brief motion bursts between dips. These aren't real points — absorb them.
        let minRally = shuttlePrimary ? config.shuttleMinRallyAbsorb : config.minRallyDuration
        let absorbed = split.map { seg -> TimeSegment in
            if seg.label == .rally && seg.duration < minRally {
                return TimeSegment(start: seg.start, end: seg.end, label: .betweenPoints, confidence: 0.3)
            }
            return seg
        }
        let cleaned = SegmentUtils.removeInvalid(absorbed)
        // Final merge gap: absorbed fragments create small gaps between consecutive
        // break segments that need bridging. This is safe because rally segments
        // separated by less than the gap would have been classified as one rally.
        return SegmentUtils.mergeAdjacent(cleaned, maxGap: config.finalMergeGap)
    }

    // MARK: - Combined Score Computation

    /// Computes per-frame combined scores. When ML shuttle position data is available,
    /// uses shuttle displacement velocity (is the shuttle *moving*?) as the ML signal.
    /// Shuttle detected but stationary = break. Shuttle moving across court = rally.
    /// Falls back to original motion+audio formula when no ML data.
    private func computeCombinedScores(frames: [FeatureFrame], shuttlePrimary: Bool, config: AnalysisConfig) -> [Double] {
        if shuttlePrimary {
            // Blend: presence + flight-motion + motion + audio (weights in config).
            // Presence captures shuttle disappearance during breaks.
            // Flight-motion (flightScore - motionScore, smoothed) captures rallies where
            // shuttle is confidently detected with low player motion. Complementary to
            // presence: strong for IMG_6156 (d=1.93) where presence is weak (d=0.54),
            // and presence is strong for IMG_8510 (d=1.79) where flight-motion is weak.
            let presenceScores = computeShuttlePresenceScores(frames: frames)
            let flightMotionScores = computeFlightMotionScores(frames: frames)
            return frames.indices.map { i in
                min(config.shuttleBlendPresenceWeight * presenceScores[i]
                    + config.shuttleBlendFlightMotionWeight * flightMotionScores[i]
                    + config.shuttleBlendMotionWeight * frames[i].motionScore
                    + config.shuttleBlendAudioWeight * frames[i].audioScore, 1.0)
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

    /// Computes per-frame flight-motion score: how strongly the shuttle is detected
    /// relative to player motion. High values (shuttle visible + low motion) indicate
    /// active rally; low values (shuttle absent or correlating with motion) indicate breaks.
    /// Smoothed with 15-frame rolling average (~3s at 5fps) for stability.
    private func computeFlightMotionScores(frames: [FeatureFrame]) -> [Double] {
        let raw = frames.map { max(0.0, $0.shuttlecockFlightScore - $0.motionScore) }
        return rollingAverage(raw, windowSize: 15)
    }

    /// Returns true when ML shuttle position data is meaningfully present
    /// (enough frames carry a position for the ML signal to be trusted).
    private func useShuttlePrimary(frames: [FeatureFrame], config: AnalysisConfig) -> Bool {
        guard !frames.isEmpty else { return false }
        let positionCount = frames.filter { $0.shuttlecockPosition != nil }.count
        let positionRate = Double(positionCount) / Double(frames.count)
        return positionRate > config.shuttlePositionRateThreshold
    }

    // MARK: - Rally Splitting

    /// Splits rally segments longer than `maxExpectedRallyDuration` at internal
    /// activity dips, which indicate between-point pauses that were missed.
    private func splitLongRallies(segments: [TimeSegment], frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        guard !frames.isEmpty else { return segments }

        let shuttlePrimary = useShuttlePrimary(frames: frames, config: config)

        var result: [TimeSegment] = []

        // Shuttle-primary: lower duration threshold — badminton rallies rarely
        // exceed 15s; the fallback threshold misses 20-24s segments containing
        // 2 points with a bird-pickup pause between.
        let maxDuration = shuttlePrimary ? config.shuttleMaxRallyDuration : config.maxExpectedRallyDuration

        for segment in segments {
            guard segment.label == .rally && segment.duration > maxDuration else {
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
                // Combined continuous dip score: normalize each signal within the
                // rally's own range, then weight-combine. Catches subtle breaks where
                // ALL signals dip partially but none crosses its individual threshold.
                // E.g., presence=0.55, FM=0.28, motion=0.24, audio=0.37 — no single
                // binary detector fires, but the combined normalized score is low.
                let presence = rallyFrames.map { $0.shuttlecockPosition != nil ? 1.0 : 0.0 }
                let presenceRoll10 = rollingAverage(presence, windowSize: 10)

                let motionRoll5 = rollingAverage(rallyFrames.map(\.motionScore), windowSize: 5)
                let audioRoll3 = rollingAverage(rallyFrames.map(\.audioScore), windowSize: 3)

                let flightMotionRaw = rallyFrames.map { max(0.0, $0.shuttlecockFlightScore - $0.motionScore) }
                let flightMotionRoll15 = rollingAverage(flightMotionRaw, windowSize: 15)

                let presNorm = normalizeToRange(presenceRoll10)
                let fmNorm = normalizeToRange(flightMotionRoll15)
                let motionNorm = normalizeToRange(motionRoll5)
                let audioNorm = normalizeToRange(audioRoll3)

                // dipScore: high = likely break, low = likely rally
                // Invert so low = dip, high = active (consistent with findDips)
                scores = (0..<rallyFrames.count).map { i in
                    let dipScore = config.dipPresenceWeight * (1 - presNorm[i])
                                 + config.dipFlightMotionWeight * (1 - fmNorm[i])
                                 + config.dipMotionWeight * (1 - motionNorm[i])
                                 + config.dipAudioWeight * (1 - audioNorm[i])
                    return 1.0 - dipScore
                }

                // Progressive splitting: scale sensitivity by duration.
                // Longer rallies almost certainly contain missed breaks.
                if segment.duration > 30 {
                    dipThreshold = config.dipThresholdLong
                    minDipDur = config.dipMinDurationLong
                } else if segment.duration > 20 {
                    dipThreshold = config.dipThresholdMedium
                    minDipDur = config.dipMinDurationMedium
                } else {
                    dipThreshold = config.dipThresholdStandard
                    minDipDur = config.dipMinDurationStandard
                }
            } else {
                let allScores = computeCombinedScores(frames: frames, shuttlePrimary: false, config: config)
                let classificationThreshold = percentile(allScores, p: config.rallyPercentile)
                scores = computeCombinedScores(frames: rallyFrames, shuttlePrimary: false, config: config)
                dipThreshold = classificationThreshold * 0.7
                minDipDur = config.minDipDuration
            }

            // Smooth with rolling average to reduce frame-to-frame noise.
            // 5-frame window (≈1s) bridges brief 1-2 frame gaps in the signal.
            // For shuttle-primary binary dip signal, threshold 0.5 after smoothing
            // means majority of the window must be dip frames.
            let smoothWindow = 5
            let smoothed = rollingAverage(scores, windowSize: smoothWindow)

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

    /// Normalizes values to [0, 1] within their own range (min→0, max→1).
    /// If the range is negligible (<0.01), returns 0.5 for all values.
    private func normalizeToRange(_ values: [Double]) -> [Double] {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let range = hi - lo
        guard range > 0.01 else { return values.map { _ in 0.5 } }
        return values.map { ($0 - lo) / range }
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

    /// Otsu's method: finds the threshold that maximizes between-class variance,
    /// giving the optimal binary split of a bimodal distribution.
    /// Result is clamped to [min, max] to prevent pathological edge cases.
    private func otsuThreshold(_ values: [Double], min minVal: Double, max maxVal: Double) -> Double {
        guard values.count >= 2 else { return (minVal + maxVal) / 2.0 }

        let sorted = values.sorted()
        let n = Double(values.count)
        let totalSum = sorted.reduce(0, +)

        var bestThreshold = (minVal + maxVal) / 2.0
        var bestVariance = -1.0

        var weightBg = 0.0
        var sumBg = 0.0

        for i in 0..<sorted.count - 1 {
            weightBg += 1.0
            sumBg += sorted[i]

            let weightFg = n - weightBg
            if weightFg == 0 { continue }

            let meanBg = sumBg / weightBg
            let meanFg = (totalSum - sumBg) / weightFg

            let variance = weightBg * weightFg * (meanBg - meanFg) * (meanBg - meanFg)

            // Use midpoint between current and next value as candidate threshold
            let candidate = (sorted[i] + sorted[i + 1]) / 2.0

            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = candidate
            }
        }

        return Swift.min(Swift.max(bestThreshold, minVal), maxVal)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pp = max(0, min(1, p))
        let idx = Int(Double(sorted.count - 1) * pp)
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
