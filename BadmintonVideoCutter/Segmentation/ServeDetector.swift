import Foundation
import AVFoundation
import CoreGraphics

final class ServeDetector {

    enum ServeSide: String, Codable, Sendable {
        case left
        case right
        case unknown
    }

    /// Which frame axis separates the two parties. Horizontal camera setups
    /// split left|right; end-of-court setups split near|far (vertical).
    enum Axis: String, Codable, Sendable {
        case horizontal
        case vertical
    }

    struct PointScore: Sendable {
        var scoreA: Int  // First server's score
        var scoreB: Int  // Other player's score

        var display: String {
            "\(scoreA):\(scoreB)"
        }
    }

    /// Detect which side of the court serves each point by computing the
    /// motion centroid at each rally start, then clustering into two groups.
    /// Adapts to any camera angle — uses whichever spatial axis (X or Y)
    /// best separates the two players.
    static func detectServes(videoURL: URL, points: [GamePoint]) async -> [UUID: ServeSide] {
        await detectServesWithAxis(videoURL: videoURL, points: points).sides
    }

    static func detectServesWithAxis(videoURL: URL, points: [GamePoint]) async -> (sides: [UUID: ServeSide], axis: Axis) {
        let full = await detectServesWithConfidence(videoURL: videoURL, points: points)
        return (full.sides, full.axis)
    }

    // MARK: - Serve-moment + Shuttle Evidence (G4/G5)

    /// The serve moment inside a play: the first audio onset shortly after
    /// the play's start (plays begin with pre-roll), else the start itself.
    static func serveAnchorTime(start: TimeInterval, onsets: [TimeInterval]) -> TimeInterval {
        onsets.first { $0 >= start && $0 <= start + 2.0 } ?? start
    }

    /// Where the shuttle first appears in a play — it originates at the
    /// server. Cached TrackNet positions, no video decode. nil when the
    /// shuttle wasn't tracked early in the play.
    static func shuttleCentroid(
        start: TimeInterval,
        frames: [FeatureFrame],
        onsets: [TimeInterval]
    ) -> (x: Double, y: Double)? {
        let t0 = serveAnchorTime(start: start, onsets: onsets)
        var xs: [Double] = []
        var ys: [Double] = []
        for frame in frames where frame.timestamp >= t0 - 0.2 {
            if frame.timestamp > t0 + 1.2 { break }
            if let pos = frame.shuttlecockPosition {
                xs.append(pos.x)
                ys.append(pos.y)
                if xs.count >= 5 { break }
            }
        }
        guard xs.count >= 2 else { return nil }
        return (xs.reduce(0, +) / Double(xs.count), ys.reduce(0, +) / Double(ys.count))
    }

    /// Full detection incl. per-point confidence. Evidence per play, in
    /// order of preference (G5): the shuttle's first tracked positions
    /// (cached frames, originates at the server), else the motion centroid
    /// of video frames — both sampled around the serve moment (G4: first
    /// audio onset after the play start). Sides come from a largest-gap
    /// cluster split per evidence source; `preferredAxis` (G6) reuses the
    /// persisted axis so incremental passes can't flip it.
    static func detectServesWithConfidence(
        videoURL: URL,
        points: [GamePoint],
        frames: [FeatureFrame] = [],
        onsets: [TimeInterval] = [],
        preferredAxis: Axis? = nil
    ) async -> (sides: [UUID: ServeSide], axis: Axis, margins: [UUID: Double]) {
        let pointData = points.map { (id: $0.id, start: $0.start, number: $0.pointNumber) }
        guard !pointData.isEmpty else { return ([:], .horizontal, [:]) }

        // Shuttle evidence comes from cached frames — resolve before the
        // video-decoding task.
        var shuttle: [UUID: (x: Double, y: Double)] = [:]
        if !frames.isEmpty {
            for point in pointData {
                if let c = shuttleCentroid(start: point.start, frames: frames, onsets: onsets) {
                    shuttle[point.id] = c
                }
            }
        }
        let shuttleEvidence = shuttle
        let onsetTimes = onsets

        return await Task.detached {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            // Step 1: evidence per play — shuttle first, motion fallback.
            var centroids: [(id: UUID, cx: Double, cy: Double, source: String)] = []
            var log: [String] = []
            log.append("════════ SERVE DETECTION RUN — \(Date()) ════════")
            log.append("video: \(videoURL.lastPathComponent)  plays: \(pointData.count)  shuttle evidence: \(shuttleEvidence.count)")
            log.append("window: serve moment (first audio onset in start+0..2s, else start) — shuttle positions preferred, motion centroid fallback")
            var grabFailures = 0
            var failedIDs: [UUID] = []

            for point in pointData {
                if let c = shuttleEvidence[point.id] {
                    centroids.append((id: point.id, cx: c.x, cy: c.y, source: "shuttle"))
                    continue
                }
                let anchor = serveAnchorTime(start: point.start, onsets: onsetTimes)
                let t0 = CMTime(seconds: anchor + 0.1, preferredTimescale: 600)
                let t1 = CMTime(seconds: anchor + 0.5, preferredTimescale: 600)
                let t2 = CMTime(seconds: anchor + 0.9, preferredTimescale: 600)

                guard let img0 = try? generator.copyCGImage(at: t0, actualTime: nil),
                      let img1 = try? generator.copyCGImage(at: t1, actualTime: nil) else {
                    failedIDs.append(point.id)
                    grabFailures += 1
                    log.append(String(format: "play #%d t=%.1fs  FRAME GRAB FAILED → excluded from clustering, side=UNKNOWN", point.number, point.start))
                    continue
                }

                let (cx1, cy1) = computeMotionCentroid(img0, img1)

                // Average with a second frame pair for robustness
                if let img2 = try? generator.copyCGImage(at: t2, actualTime: nil) {
                    let (cx2, cy2) = computeMotionCentroid(img0, img2)
                    centroids.append((id: point.id, cx: (cx1 + cx2) / 2, cy: (cy1 + cy2) / 2, source: "motion"))
                } else {
                    centroids.append((id: point.id, cx: cx1, cy: cy1, source: "motion"))
                }
            }

            guard centroids.count >= 2 else {
                // Too few usable centroids (incl. all-failed): every play unknown.
                return (Dictionary(uniqueKeysWithValues: pointData.map { ($0.id, ServeSide.unknown) }), .horizontal, [:])
            }

            // Step 2: axis — reuse the persisted one (G6) so incremental
            // passes can't flip it; else pick by spread, preferring the
            // shuttle group (cleaner signal) when it covers enough plays.
            let xValues = centroids.map(\.cx)
            let yValues = centroids.map(\.cy)
            let shuttleOnly = centroids.filter { $0.source == "shuttle" }
            let axisBasis = shuttleOnly.count >= max(3, centroids.count / 2) ? shuttleOnly : centroids
            let xVariance = variance(axisBasis.map(\.cx))
            let yVariance = variance(axisBasis.map(\.cy))
            let axis: Axis = preferredAxis ?? (xVariance >= yVariance ? .horizontal : .vertical)

            // Step 3: largest-gap cluster split PER EVIDENCE SOURCE (shuttle
            // and motion measure the same physical axis but with different
            // biases — mixing them shifts the boundary). Rally scoring makes
            // serve counts unbalanced, which the gap split accepts.
            var results: [UUID: ServeSide] = [:]
            var margins: [UUID: Double] = [:]
            log.append(String(format: "axis: %@%@ (xVar=%.5f yVar=%.5f, basis=%@)",
                              axis == .horizontal ? "horizontal (left|right)" : "vertical (far|near)",
                              preferredAxis != nil ? " [persisted]" : "",
                              xVariance, yVariance,
                              axisBasis.count == shuttleOnly.count ? "shuttle" : "all"))

            for source in ["shuttle", "motion"] {
                let group = centroids.filter { $0.source == source }
                guard !group.isEmpty else { continue }
                let values = group.map { axis == .horizontal ? $0.cx : $0.cy }
                let classified = classifySides(values: values)
                log.append(String(format: "%@ split: LARGEST-GAP center=%.4f gapWidth=%.4f deadZone=%.3f  values: %@",
                                  source, classified.point, classified.gap, clusterDeadZone,
                                  values.sorted().map { String(format: "%.3f", $0) }.joined(separator: " ")))
                for (i, entry) in group.enumerated() {
                    results[entry.id] = classified.sides[i]
                    margins[entry.id] = classified.margins[i]
                    let number = pointData.first(where: { $0.id == entry.id })?.number ?? 0
                    let start = pointData.first(where: { $0.id == entry.id })?.start ?? 0
                    log.append(String(format: "play #%d t=%.1fs  src=%@  pos=(%.3f,%.3f)  axisVal=%.4f  margin=%.4f  → %@",
                                      number, start, source, entry.cx, entry.cy, values[i], classified.margins[i],
                                      classified.sides[i].rawValue.uppercased()))
                }
            }
            for id in failedIDs {
                results[id] = .unknown
            }
            let all = results.values
            log.append("sides: left=\(all.filter { $0 == .left }.count) right=\(all.filter { $0 == .right }.count) unknown=\(all.filter { $0 == .unknown }.count) (unbalance is EXPECTED under rally scoring)")
            if grabFailures > 0 {
                log.append("grab failures: \(grabFailures) — excluded from clustering (no placeholder pollution)")
            }
            let block = "\n" + log.joined(separator: "\n") + "\n"
            if let handle = FileHandle(forWritingAtPath: "/tmp/serve_detection_log.txt") {
                handle.seekToEndOfFile()
                handle.write(block.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? block.write(toFile: "/tmp/serve_detection_log.txt", atomically: true, encoding: .utf8)
            }

            return (results, axis, margins)
        }.value
    }

    // MARK: - Cluster Split (1-D, unbalanced-friendly)

    /// Values closer than this to the split boundary are too ambiguous to
    /// call (normalized frame coordinates).
    static let clusterDeadZone = 0.015

    /// 1-D two-cluster split: the boundary sits mid-way across the largest
    /// gap between sorted neighbor values. Unlike a median split it accepts
    /// arbitrarily unbalanced clusters — which rally scoring guarantees,
    /// since the winner keeps serving.
    static func clusterSplit(values: [Double]) -> (point: Double, gap: Double) {
        let sorted = values.sorted()
        guard sorted.count >= 2 else { return (sorted.first ?? 0.5, 0) }
        var bestGap = -1.0
        var bestPoint = sorted[0]
        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1] - sorted[i]
            if gap > bestGap {
                bestGap = gap
                bestPoint = (sorted[i + 1] + sorted[i]) / 2
            }
        }
        return (bestPoint, bestGap)
    }

    /// Classify each value against the cluster split; margin = distance to
    /// the boundary. Values inside the dead zone are unknown — with a mushy
    /// distribution (no real gap) most plays honestly come out unknown
    /// instead of being force-assigned.
    static func classifySides(values: [Double]) -> (sides: [ServeSide], margins: [Double], point: Double, gap: Double) {
        let split = clusterSplit(values: values)
        var sides: [ServeSide] = []
        var margins: [Double] = []
        for val in values {
            let margin = abs(val - split.point)
            margins.append(margin)
            if margin <= clusterDeadZone {
                sides.append(.unknown)
            } else {
                sides.append(val < split.point ? .left : .right)
            }
        }
        return (sides, margins, split.point, split.gap)
    }

    // MARK: - Sequence Inference (G2)

    /// Small bonus for a side CHANGE on plays whose own serve is unobserved:
    /// empirically (corrections log 2026-07-21) unknown serves correlate
    /// with side switches — mixed motion at the changeover confuses the
    /// classifier, and "leader kept serving" guesses were wrong 9/9.
    private static let unknownSwitchBonus = 0.005

    /// Maximum-evidence serve sequence for ONE game whose implied score
    /// chain is LEGAL (no play after a terminal score). Dynamic program
    /// over (play, side, A-wins): emissions are classification margins
    /// (+m matching the observation, −m contradicting, 0 for unknown),
    /// pins are hard constraints. Fills unknown serves from context and
    /// repairs isolated misdetections that would make the chain illegal —
    /// impossible scores like 23:9 cannot be produced.
    /// Returns one side per play; falls back to the raw observations when
    /// pins themselves force an illegal chain (validator will flag it).
    static func inferSides(
        observed: [ServeSide?],
        margins: [Double],
        pinned: [ServeSide?]
    ) -> [ServeSide] {
        let n = observed.count
        let fallback: [ServeSide] = (0..<n).map { pinned[$0] ?? observed[$0] ?? .unknown }
        guard n >= 2 else { return fallback }

        // nil = this (play, side) choice is forbidden by a pin.
        func emission(_ i: Int, _ side: ServeSide) -> Double? {
            if let pin = pinned[i], pin != .unknown {
                return side == pin ? 0 : nil
            }
            guard let obs = observed[i], obs != .unknown else { return 0 }
            return side == obs ? margins[i] : -margins[i]
        }

        struct Key: Hashable {
            let left: Bool
            let aWins: Int
        }
        var best: (score: Double, sides: [ServeSide])?

        for anchor in [ServeSide.left, .right] {
            var layer: [Key: (score: Double, path: [ServeSide])] = [:]
            for side in [ServeSide.left, .right] {
                guard let e = emission(0, side) else { continue }
                layer[Key(left: side == .left, aWins: 0)] = (e, [side])
            }
            for i in 1..<n {
                var next: [Key: (score: Double, path: [ServeSide])] = [:]
                for (key, value) in layer {
                    let prevSide: ServeSide = key.left ? .left : .right
                    for side in [ServeSide.left, .right] {
                        guard var e = emission(i, side) else { continue }
                        if observed[i] == nil || observed[i] == .unknown, side != prevSide {
                            e += unknownSwitchBonus
                        }
                        // Server of play i is the winner of play i-1.
                        let aWins = key.aWins + (side == anchor ? 1 : 0)
                        // Play i exists, so the score after play i-1 must not
                        // already be terminal.
                        guard !ScoreValidator.isTerminal(aWins, i - aWins) else { continue }
                        let candidate = (score: value.score + e, path: value.path + [side])
                        let nextKey = Key(left: side == .left, aWins: aWins)
                        if next[nextKey] == nil || next[nextKey]!.score < candidate.score {
                            next[nextKey] = candidate
                        }
                    }
                }
                layer = next
            }
            for (_, value) in layer where best == nil || value.score > best!.score {
                best = (value.score, value.path)
            }
        }
        return best?.sides ?? fallback
    }

    // MARK: - Motion Analysis

    /// Compute the center of mass of motion between two frames.
    /// Returns (cx, cy) normalized to [0, 1] where (0,0) = top-left.
    private static func computeMotionCentroid(_ img1: CGImage, _ img2: CGImage) -> (cx: Double, cy: Double) {
        let width = 160
        let height = 90

        guard let data1 = renderToPixels(img1, width: width, height: height),
              let data2 = renderToPixels(img2, width: width, height: height) else {
            return (0.5, 0.5)
        }

        var weightedX: Double = 0
        var weightedY: Double = 0
        var totalWeight: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let diff = Double(
                    abs(Int(data1[idx]) - Int(data2[idx])) +
                    abs(Int(data1[idx + 1]) - Int(data2[idx + 1])) +
                    abs(Int(data1[idx + 2]) - Int(data2[idx + 2]))
                )
                weightedX += Double(x) * diff
                weightedY += Double(y) * diff
                totalWeight += diff
            }
        }

        guard totalWeight > 0 else { return (0.5, 0.5) }
        return (
            cx: weightedX / (totalWeight * Double(width)),
            cy: weightedY / (totalWeight * Double(height))
        )
    }

    /// Render a CGImage to a fixed-size RGBA pixel buffer.
    private static func renderToPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    private static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
    }

    // MARK: - Score Computation

    /// Compute running scores for points within a single game.
    /// Player A = whoever serves the first point of the game.
    /// Rule: winner of point N serves point N+1.
    /// So if same side serves consecutive points → server won.
    /// If side changes → receiver won.
    /// Scores shown are cumulative AFTER each point is played.
    static func computeScores(
        points: [GamePoint],
        serveSides: [UUID: ServeSide],
        nextGameFirstServe: ServeSide? = nil,
        firstServe explicitFirstServe: ServeSide? = nil,
        lastPointWinner: ServeSide? = nil,
        adjustments: [UUID: PointScore] = [:],
        adjustmentsBefore: [UUID: PointScore] = [:]
    ) -> [UUID: PointScore] {
        computeScoresWithTrace(points: points, serveSides: serveSides,
                               nextGameFirstServe: nextGameFirstServe,
                               firstServe: explicitFirstServe,
                               lastPointWinner: lastPointWinner,
                               adjustments: adjustments,
                               adjustmentsBefore: adjustmentsBefore).scores
    }

    /// Same computation, plus a per-play natural-language derivation trace
    /// ("how did this play get its winner") for the diagnostics log.
    static func computeScoresWithTrace(
        points: [GamePoint],
        serveSides: [UUID: ServeSide],
        nextGameFirstServe: ServeSide? = nil,
        firstServe explicitFirstServe: ServeSide? = nil,
        lastPointWinner: ServeSide? = nil,
        adjustments: [UUID: PointScore] = [:],
        adjustmentsBefore: [UUID: PointScore] = [:]
    ) -> (scores: [UUID: PointScore], trace: [UUID: String]) {
        let activePoints = points.filter { $0.reviewStatus != .deleted }
        guard !activePoints.isEmpty else { return ([:], [:]) }

        // Player A = the side that serves the game's FIRST point. Callers
        // should pass it explicitly so score columns and UI labels share one
        // anchor; the fallback infers from the earliest known side.
        let firstServe: ServeSide
        if let explicitFirstServe, explicitFirstServe != .unknown {
            firstServe = explicitFirstServe
        } else if let known = activePoints.first(where: { serveSides[$0.id] != nil && serveSides[$0.id] != .unknown }) {
            firstServe = serveSides[known.id]!
        } else {
            return ([:], [:])
        }

        var scoreA = 0
        var scoreB = 0
        var results: [UUID: PointScore] = [:]
        var trace: [UUID: String] = [:]
        func letter(_ side: ServeSide) -> String { side == firstServe ? "A" : "B" }

        for i in 0..<activePoints.count {
            // Manual score-at-serve override: rebase BEFORE this play's
            // winner increment is applied.
            var setBefore: String?
            if let adj = adjustmentsBefore[activePoints[i].id] {
                scoreA = adj.scoreA
                scoreB = adj.scoreB
                setBefore = "entering score MANUALLY SET to \(adj.scoreA):\(adj.scoreB) ; "
            }
            // Rally scoring: the winner of point N is exactly the side that
            // serves point N+1. Using only the NEXT serve (not the transition)
            // means one misdetected side corrupts one point, not two, and a
            // point whose own serve is unknown still scores correctly.
            let winnerSide: ServeSide
            var how = ""
            if i == activePoints.count - 1, let lastPointWinner, lastPointWinner != .unknown {
                // An explicit winner override on the game's final play beats
                // the next game's first serve — that serve may be a pin
                // anchoring the NEXT game, not evidence about this play.
                winnerSide = lastPointWinner
                how = "explicit final-play winner override (\(lastPointWinner.rawValue))"
            } else if i < activePoints.count - 1 {
                winnerSide = serveSides[activePoints[i + 1].id] ?? .unknown
                how = winnerSide == .unknown
                    ? "next play's serve UNKNOWN"
                    : "next play (#\(activePoints[i + 1].pointNumber)) served by \(winnerSide.rawValue)"
            } else {
                winnerSide = nextGameFirstServe ?? .unknown
                how = winnerSide == .unknown
                    ? "final play, no next-game serve"
                    : "next GAME's first serve by \(winnerSide.rawValue)"
            }

            if winnerSide != .unknown {
                if winnerSide == firstServe { scoreA += 1 } else { scoreB += 1 }
                trace[activePoints[i].id] = "winner=\(letter(winnerSide)) — \(how)"
            } else if i == activePoints.count - 1 {
                // Last point with no following game: an explicit winner
                // override decides; else leader likely won; tie → server.
                let currentServe = serveSides[activePoints[i].id] ?? .unknown
                if scoreA != scoreB {
                    let leader = scoreA > scoreB ? "A" : "B"
                    if scoreA > scoreB { scoreA += 1 } else { scoreB += 1 }
                    trace[activePoints[i].id] = "winner=\(leader) — GUESS (\(how); assumed leader won)"
                } else if currentServe != .unknown, currentServe != firstServe {
                    scoreB += 1
                    trace[activePoints[i].id] = "winner=B — GUESS (\(how); tie, assumed server B won)"
                } else {
                    scoreA += 1
                    trace[activePoints[i].id] = "winner=A — GUESS (\(how); tie, assumed server/A won)"
                }
            } else {
                // Next serve unknown mid-game — best guess: leader won.
                let guessed = scoreA >= scoreB ? "A" : "B"
                if scoreA >= scoreB { scoreA += 1 } else { scoreB += 1 }
                trace[activePoints[i].id] = "winner=\(guessed) — GUESS (\(how); assumed leader won)"
            }

            // Manual running-score override: the user knows the score after
            // this play (players miscounted on court, or the chain drifted).
            // Later plays accumulate from the set value.
            if let adj = adjustments[activePoints[i].id] {
                scoreA = adj.scoreA
                scoreB = adj.scoreB
                trace[activePoints[i].id] = (trace[activePoints[i].id] ?? "") + " ; score MANUALLY SET to \(adj.scoreA):\(adj.scoreB)"
            }
            if let setBefore {
                trace[activePoints[i].id] = setBefore + (trace[activePoints[i].id] ?? "")
            }
            results[activePoints[i].id] = PointScore(scoreA: scoreA, scoreB: scoreB)
        }

        return (results, trace)
    }
}

/// Badminton rules sanity checks over a game's running score.
enum ScoreValidator {

    /// A score is terminal when the game is over at that state.
    static func isTerminal(_ a: Int, _ b: Int) -> Bool {
        let hi = max(a, b), lo = min(a, b)
        if hi == 30 { return true }
        return hi >= 21 && hi - lo >= 2
    }

    /// First rules violation in an ordered score chain, if any:
    /// points recorded after the game already ended, or a column past 30.
    static func firstViolation(orderedScores: [(pointID: UUID, score: ServeDetector.PointScore)])
        -> (pointID: UUID, reason: String)? {
        for (index, entry) in orderedScores.enumerated() where index > 0 {
            let prev = orderedScores[index - 1].score
            if isTerminal(prev.scoreA, prev.scoreB) {
                return (entry.pointID,
                        "Game already ended at \(prev.scoreA):\(prev.scoreB) — later plays can't belong to it.")
            }
            let cur = entry.score
            if max(cur.scoreA, cur.scoreB) > 30 {
                return (entry.pointID, "A game never goes past 30.")
            }
        }
        return nil
    }

    /// Which plays' winners to flip so the A-win count moves by `delta`
    /// (positive = flip A-wins to B). Prefers the LOWEST-confidence calls;
    /// pinned (user-confirmed) plays are never chosen. Returns indices.
    static func chooseFlips(winnersIsA: [Bool?], margins: [Double], pinned: [Bool], delta: Int) -> [Int] {
        guard delta != 0 else { return [] }
        let flipFromA = delta > 0
        let candidates = winnersIsA.indices
            .filter { winnersIsA[$0] == flipFromA && !pinned[$0] }
            .sorted { margins[$0] < margins[$1] }
        return Array(candidates.prefix(abs(delta)))
    }
}
