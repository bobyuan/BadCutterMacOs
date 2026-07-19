import Foundation

// MARK: - Hit Detection

/// Trajectory-based hit detection (DESIGN §5.1): a shot is a direction change
/// in the shuttle's vertical travel (descending → ascending), fused with audio
/// onsets so exchanges the tracker misses still count.
enum HitDetector {

    /// Minimum spacing between two detected hits.
    static let minHitSpacing: TimeInterval = 0.3

    /// Per-hit timestamps within a segment, sorted ascending.
    static func detectHits(frames: [FeatureFrame], in segment: TimeSegment) -> [TimeInterval] {
        let window = frames.filter { $0.timestamp >= segment.start && $0.timestamp <= segment.end }
        guard !window.isEmpty else { return [] }

        var hits = trajectoryHits(in: window)
        // Fuse in audio onsets that trajectory missed (dedup within 0.25s).
        for onset in audioOnsets(in: window) where !hits.contains(where: { abs($0 - onset) < 0.25 }) {
            hits.append(onset)
        }
        hits.sort()

        // Enforce minimum spacing after fusion.
        var spaced: [TimeInterval] = []
        for hit in hits where spaced.last.map({ hit - $0 >= minHitSpacing }) ?? true {
            spaced.append(hit)
        }
        return spaced
    }

    /// Vertical-velocity sign changes from descending (vy > 0, screen y grows
    /// downward) to ascending (vy < 0) — the moment a falling shuttle is struck
    /// back up. Position gaps > 0.2s break continuity (tracker lost the bird).
    private static func trajectoryHits(in window: [FeatureFrame]) -> [TimeInterval] {
        struct Sample { let t: TimeInterval; let y: Double }
        let samples = window.compactMap { frame in
            frame.shuttlecockPosition.map { Sample(t: frame.timestamp, y: $0.y) }
        }
        guard samples.count >= 4 else { return [] }

        var hits: [TimeInterval] = []
        var previousVy: Double?
        for i in 1..<samples.count {
            let dt = samples[i].t - samples[i - 1].t
            guard dt > 0, dt <= 0.2 else {
                previousVy = nil
                continue
            }
            let vy = (samples[i].y - samples[i - 1].y) / dt
            if let prev = previousVy, prev > 0, vy < 0,
               hits.last.map({ samples[i].t - $0 >= minHitSpacing }) ?? true {
                hits.append(samples[i].t)
            }
            previousVy = vy
        }
        return hits
    }

    /// Rising edges of the (quantized) audio score into the ≥ 0.5 band.
    private static func audioOnsets(in window: [FeatureFrame]) -> [TimeInterval] {
        var onsets: [TimeInterval] = []
        var previousHigh = false
        for frame in window {
            let high = frame.audioScore >= 0.5
            if high, !previousHigh,
               onsets.last.map({ frame.timestamp - $0 >= minHitSpacing }) ?? true {
                onsets.append(frame.timestamp)
            }
            previousHigh = high
        }
        return onsets
    }
}

// MARK: - Highlight Scoring

/// Heuristic highlight scoring (DESIGN §3.4): six per-point features, each
/// normalized to its in-video percentile, combined with fixed weights into a
/// score in [0, 1]. Transparent by design — the learned ranker (Phase 7)
/// replaces the weights, not the features.
enum HighlightScorer {

    struct PointFeatures {
        var duration: Double = 0
        var hitCount: Double = 0
        var tempo: Double = 0
        var maxShuttleSpeed: Double = 0
        var avgMotion: Double = 0
        var climax: Double = 0
    }

    static let weights = PointFeatures(
        duration: 0.25, hitCount: 0.15, tempo: 0.20,
        maxShuttleSpeed: 0.20, avgMotion: 0.08, climax: 0.12
    )

    static func features(for segment: TimeSegment, frames: [FeatureFrame]) -> PointFeatures {
        let window = frames.filter { $0.timestamp >= segment.start && $0.timestamp <= segment.end }
        var f = PointFeatures()
        f.duration = segment.duration

        let hits = HitDetector.detectHits(frames: frames, in: segment)
        f.hitCount = Double(hits.count)
        f.tempo = segment.duration > 0 ? f.hitCount / segment.duration : 0

        // Max displacement speed over consecutive tracked frames (smash proxy).
        var lastPos: (t: TimeInterval, x: Double, y: Double)?
        for frame in window {
            guard let pos = frame.shuttlecockPosition else { continue }
            if let last = lastPos {
                let dt = frame.timestamp - last.t
                if dt > 0, dt <= 0.15 {
                    let dist = ((pos.x - last.x) * (pos.x - last.x) + (pos.y - last.y) * (pos.y - last.y)).squareRoot()
                    f.maxShuttleSpeed = max(f.maxShuttleSpeed, dist / dt)
                }
            }
            lastPos = (frame.timestamp, pos.x, pos.y)
        }

        guard !window.isEmpty else { return f }
        f.avgMotion = window.map(\.motionScore).reduce(0, +) / Double(window.count)

        // Audio in the final 1.5s relative to the point's mean — dramatic finish.
        let tail = window.filter { $0.timestamp >= segment.end - 1.5 }
        let meanAudio = window.map(\.audioScore).reduce(0, +) / Double(window.count)
        if !tail.isEmpty, meanAudio > 0.01 {
            let tailAudio = tail.map(\.audioScore).reduce(0, +) / Double(tail.count)
            f.climax = tailAudio / meanAudio
        }
        return f
    }

    /// Feature order shared by the heuristic weights and the learned ranker.
    static let featureNames = ["duration", "hitCount", "tempo", "maxShuttleSpeed", "avgMotion", "climax"]

    /// Per-point features normalized to their in-video percentile, in
    /// `featureNames` order. Scale-free, so they compare across videos —
    /// both the heuristic and the learned ranker consume these.
    static func percentileFeatureVectors(points: [GamePoint], frames: [FeatureFrame]) -> [UUID: [Double]] {
        guard !points.isEmpty else { return [:] }
        let featureList = points.map { features(for: $0.rallySegment, frames: frames) }

        func percentiles(_ keyPath: KeyPath<PointFeatures, Double>) -> [Double] {
            let values = featureList.map { $0[keyPath: keyPath] }
            guard values.count > 1 else { return [0.5] }
            return values.map { v in
                Double(values.filter { $0 < v }.count) / Double(values.count - 1)
            }
        }

        let columns = [
            percentiles(\.duration), percentiles(\.hitCount), percentiles(\.tempo),
            percentiles(\.maxShuttleSpeed), percentiles(\.avgMotion), percentiles(\.climax)
        ]
        var result: [UUID: [Double]] = [:]
        for (i, point) in points.enumerated() {
            result[point.id] = columns.map { $0[i] }
        }
        return result
    }

    /// Score each point against the others in the same video (fixed weights).
    static func scores(points: [GamePoint], frames: [FeatureFrame]) -> [UUID: Double] {
        let vectors = percentileFeatureVectors(points: points, frames: frames)
        let w = [weights.duration, weights.hitCount, weights.tempo,
                 weights.maxShuttleSpeed, weights.avgMotion, weights.climax]
        return vectors.mapValues { vector in
            zip(vector, w).reduce(0) { $0 + $1.0 * $1.1 }
        }
    }

    // MARK: - Highlight Selection

    /// Points the highlight reel should contain, in chronological order.
    /// `threshold` may select nothing; the other policies always pick at
    /// least the single best point.
    static func select(points: [GamePoint], scores: [UUID: Double], selection: HighlightSelection) -> [GamePoint] {
        guard !points.isEmpty else { return [] }
        let ranked = points.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }

        var picked: [GamePoint]
        switch selection {
        case .topPercent(let percent):
            let count = max(1, Int((Double(points.count) * percent / 100).rounded()))
            picked = Array(ranked.prefix(count))
        case .topMinutes(let minutes):
            let budget = minutes * 60
            picked = []
            var total: TimeInterval = 0
            for point in ranked {
                if !picked.isEmpty, total + point.duration > budget { continue }
                picked.append(point)
                total += point.duration
            }
        case .threshold(let minScore):
            picked = ranked.filter { (scores[$0.id] ?? 0) >= minScore }
        }
        return picked.sorted { $0.start < $1.start }
    }
}
