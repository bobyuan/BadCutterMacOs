import Foundation

/// Turns a 👎 feedback reason into a concrete boundary fix, using the same
/// signals the pipeline already has: shuttle presence, motion, and the
/// Phase 8 audio onsets. Pure and deterministic — every proposal is applied
/// through the ordinary ledger paths, so it is always one ⌘Z from undone.
enum PointAdjuster {

    struct Context {
        var point: GamePoint
        /// End of the previous active point (0 when none).
        var previousEnd: TimeInterval
        /// Start of the next active point (video duration when none).
        var nextStart: TimeInterval
        var frames: [FeatureFrame]
        var onsets: [TimeInterval]
        var videoDuration: TimeInterval
    }

    enum Proposal: Equatable {
        case adjustStart(to: TimeInterval)
        case adjustEnd(to: TimeInterval)
        case split(firstEnd: TimeInterval, secondStart: TimeInterval)
        case insertBefore(start: TimeInterval, end: TimeInterval)
    }

    static func propose(reason: PointFeedbackReason, context: Context) -> Proposal? {
        switch reason {
        case .startsTooEarly: return proposeStartsTooEarly(context)
        case .startsTooLate: return proposeStartsTooLate(context)
        case .endsTooEarly: return proposeEndsTooEarly(context)
        case .endsTooLate: return proposeEndsTooLate(context)
        case .shouldSplit: return proposeSplit(context)
        case .missedPointBefore: return proposeMissedPointBefore(context)
        case .notHighlight, .notAPoint: return nil
        }
    }

    // MARK: - Activity Signal

    /// True when there is rally evidence near `t`: shuttle tracked, players
    /// moving, or a racket hit within earshot.
    static func isActive(at t: TimeInterval, context: Context) -> Bool {
        if context.onsets.contains(where: { abs($0 - t) <= 0.5 }) { return true }
        let nearby = context.frames.filter { abs($0.timestamp - t) <= 0.4 }
        guard !nearby.isEmpty else { return false }
        return nearby.contains { $0.shuttlecockPosition != nil || $0.motionScore >= 0.12 }
    }

    /// Fraction of samples in [from, to] that are active (0.2s sampling).
    private static func activityFraction(from: TimeInterval, to: TimeInterval, context: Context) -> Double {
        guard to > from else { return 0 }
        var active = 0, total = 0
        var t = from
        while t <= to {
            if isActive(at: t, context: context) { active += 1 }
            total += 1
            t += 0.2
        }
        return total == 0 ? 0 : Double(active) / Double(total)
    }

    // MARK: - Boundary Reasons

    /// Dead time before the serve: anchor on the first hit/shuttle evidence
    /// inside the point and start shortly before it.
    private static func proposeStartsTooEarly(_ ctx: Context) -> Proposal? {
        let p = ctx.point
        let firstOnset = ctx.onsets.first { $0 > p.start && $0 < p.end }
        let firstPresence = ctx.frames.first {
            $0.timestamp > p.start && $0.timestamp < p.end && $0.shuttlecockPosition != nil
        }?.timestamp
        guard let anchor = [firstOnset, firstPresence].compactMap({ $0 }).min() else { return nil }
        let newStart = max(p.start, anchor - 0.7)
        guard newStart - p.start >= 0.5, newStart <= p.end - 1.0 else { return nil }
        return .adjustStart(to: newStart)
    }

    /// Dead time after the rally: anchor on the last hit/shuttle evidence and
    /// end shortly after it (birdie landing).
    private static func proposeEndsTooLate(_ ctx: Context) -> Proposal? {
        let p = ctx.point
        let lastOnset = ctx.onsets.last { $0 > p.start && $0 < p.end }
        let lastPresence = ctx.frames.last {
            $0.timestamp > p.start && $0.timestamp < p.end && $0.shuttlecockPosition != nil
        }?.timestamp
        guard let anchor = [lastOnset, lastPresence].compactMap({ $0 }).max() else { return nil }
        let newEnd = min(p.end, anchor + 1.0)
        guard p.end - newEnd >= 0.5, newEnd >= p.start + 1.0 else { return nil }
        return .adjustEnd(to: newEnd)
    }

    /// Cut off while still active: walk forward while activity persists.
    private static func proposeEndsTooEarly(_ ctx: Context) -> Proposal? {
        let p = ctx.point
        let ceiling = min(ctx.nextStart - 0.1, ctx.videoDuration)
        var t = p.end
        while t + 0.3 <= ceiling, isActive(at: t + 0.3, context: ctx) {
            t += 0.3
        }
        let newEnd = min(ceiling, t + 0.5)
        guard newEnd - p.end >= 0.5 else { return nil }
        return .adjustEnd(to: newEnd)
    }

    /// Play already going at the start: walk backward while activity persists.
    private static func proposeStartsTooLate(_ ctx: Context) -> Proposal? {
        let p = ctx.point
        let floor = max(ctx.previousEnd + 0.1, 0)
        var t = p.start
        while t - 0.3 >= floor, isActive(at: t - 0.3, context: ctx) {
            t -= 0.3
        }
        let newStart = max(floor, t - 0.5)
        guard p.start - newStart >= 0.5 else { return nil }
        return .adjustStart(to: newStart)
    }

    /// All internal low-activity stretches (>= minBreak, away from the edges)
    /// within a span — the local re-segmentation used after a play's span is
    /// extended (an extension can swallow a second rally plus its pause).
    static func internalBreaks(
        from start: TimeInterval,
        to end: TimeInterval,
        context: Context,
        minBreak: TimeInterval = 1.0
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard end - start >= 3 else { return [] }
        var breaks: [(start: TimeInterval, end: TimeInterval)] = []
        var dipStart: TimeInterval?
        var t = start + 0.8
        while t <= end - 0.8 {
            if isActive(at: t, context: context) {
                if let s0 = dipStart {
                    if t - s0 >= minBreak { breaks.append((s0, t)) }
                    dipStart = nil
                }
            } else if dipStart == nil {
                dipStart = t
            }
            t += 0.2
        }
        if let s0 = dipStart, (end - 0.8) - s0 >= minBreak {
            breaks.append((s0, end - 0.8))
        }
        return breaks
    }

    // MARK: - Structural Reasons

    /// Two merged points: split at the longest internal low-activity dip.
    private static func proposeSplit(_ ctx: Context) -> Proposal? {
        let p = ctx.point
        guard p.duration >= 4 else { return nil }

        var bestDip: (start: TimeInterval, end: TimeInterval)?
        var dipStart: TimeInterval?
        var t = p.start + 1.0
        while t <= p.end - 1.0 {
            if isActive(at: t, context: ctx) {
                if let start = dipStart {
                    let dip = (start: start, end: t)
                    if dip.end - dip.start >= 0.8,
                       dip.end - dip.start > (bestDip.map { $0.end - $0.start } ?? 0) {
                        bestDip = dip
                    }
                    dipStart = nil
                }
            } else if dipStart == nil {
                dipStart = t
            }
            t += 0.2
        }
        if let start = dipStart, p.end - 1.0 - start >= 0.8,
           p.end - 1.0 - start > (bestDip.map { $0.end - $0.start } ?? 0) {
            bestDip = (start: start, end: p.end - 1.0)
        }

        guard let dip = bestDip,
              dip.start - p.start >= 1.5, p.end - dip.end >= 1.5 else { return nil }
        return .split(firstEnd: dip.start + 0.3, secondStart: dip.end - 0.3)
    }

    /// A rally in the preceding gap that detection missed: find the
    /// highest-activity 3s window and size a point around it.
    private static func proposeMissedPointBefore(_ ctx: Context) -> Proposal? {
        let gapStart = ctx.previousEnd
        let gapEnd = ctx.point.start
        guard gapEnd - gapStart >= 3.0 else { return nil }

        var bestCenter: TimeInterval?
        var bestScore = 0.25   // require meaningful activity, not noise
        var center = gapStart + 1.5
        while center <= gapEnd - 1.5 {
            let score = activityFraction(from: center - 1.5, to: center + 1.5, context: ctx)
            if score > bestScore {
                bestScore = score
                bestCenter = center
            }
            center += 0.5
        }
        guard let peak = bestCenter else { return nil }

        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: peak,
            frames: ctx.frames,
            activeSegments: [
                TimeSegment(start: max(0, gapStart - 1), end: gapStart, label: .rally, confidence: 1),
                TimeSegment(start: gapEnd, end: min(ctx.videoDuration, gapEnd + 1), label: .rally, confidence: 1)
            ],
            videoDuration: ctx.videoDuration
        )
        return .insertBefore(start: span.start, end: span.end)
    }
}
