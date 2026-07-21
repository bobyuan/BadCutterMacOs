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

    /// Full detection incl. per-point confidence: the centroid's distance from
    /// the split median (0 = coin flip, larger = more certain).
    static func detectServesWithConfidence(videoURL: URL, points: [GamePoint]) async -> (sides: [UUID: ServeSide], axis: Axis, margins: [UUID: Double]) {
        let pointData = points.map { (id: $0.id, start: $0.start, number: $0.pointNumber) }
        guard !pointData.isEmpty else { return ([:], .horizontal, [:]) }

        return await Task.detached {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            // Step 1: Compute motion centroid for each rally start
            var centroids: [(id: UUID, cx: Double, cy: Double)] = []
            var log: [String] = []
            log.append("════════ SERVE DETECTION RUN — \(Date()) ════════")
            log.append("video: \(videoURL.lastPathComponent)  plays: \(pointData.count)")
            log.append("window: start+0.1 / +0.5 / +0.9 (motion centroid of frame pairs)")
            var grabFailures = 0
            var failedIDs: [UUID] = []

            for point in pointData {
                let t0 = CMTime(seconds: point.start + 0.1, preferredTimescale: 600)
                let t1 = CMTime(seconds: point.start + 0.5, preferredTimescale: 600)
                let t2 = CMTime(seconds: point.start + 0.9, preferredTimescale: 600)

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
                    centroids.append((id: point.id, cx: (cx1 + cx2) / 2, cy: (cy1 + cy2) / 2))
                } else {
                    centroids.append((id: point.id, cx: cx1, cy: cy1))
                }
            }

            guard centroids.count >= 2 else {
                // Too few usable centroids (incl. all-failed): every play unknown.
                return (Dictionary(uniqueKeysWithValues: pointData.map { ($0.id, ServeSide.unknown) }), .horizontal, [:])
            }

            // Step 2: Determine which axis best separates the two players
            let xValues = centroids.map(\.cx)
            let yValues = centroids.map(\.cy)
            let xVariance = variance(xValues)
            let yVariance = variance(yValues)

            // Use the axis with more spread
            let axis: Axis = xVariance >= yVariance ? .horizontal : .vertical
            let values = axis == .horizontal ? xValues : yValues

            // Step 3: cluster split at the largest interior gap. Rally
            // scoring means the winner keeps serving, so serve counts are
            // unbalanced (a 21:9 game is ~70/30) — a median split would
            // mechanically misclassify the dominant server's plays. The gap
            // between the two position clusters is the honest boundary.
            let classified = classifySides(values: values)
            var results: [UUID: ServeSide] = [:]
            var margins: [UUID: Double] = [:]

            log.append(String(format: "axis: %@ (xVar=%.5f yVar=%.5f)", axis == .horizontal ? "horizontal (left|right)" : "vertical (far|near)", xVariance, yVariance))
            log.append(String(format: "split: LARGEST-GAP center=%.4f gapWidth=%.4f deadZone=%.3f (cluster split)", classified.point, classified.gap, clusterDeadZone))
            log.append(String(format: "sorted axis values: %@", values.sorted().map { String(format: "%.3f", $0) }.joined(separator: " ")))

            for (i, entry) in centroids.enumerated() {
                results[entry.id] = classified.sides[i]
                margins[entry.id] = classified.margins[i]
                let number = pointData.first(where: { $0.id == entry.id })?.number ?? 0
                let start = pointData.first(where: { $0.id == entry.id })?.start ?? 0
                log.append(String(format: "play #%d t=%.1fs  centroid=(%.3f,%.3f)  axisVal=%.4f  margin=%.4f  → %@",
                                  number, start, entry.cx, entry.cy, values[i], classified.margins[i],
                                  classified.sides[i].rawValue.uppercased()))
            }
            for id in failedIDs {
                results[id] = .unknown
            }
            let counts = (l: classified.sides.filter { $0 == .left }.count,
                          r: classified.sides.filter { $0 == .right }.count,
                          u: classified.sides.filter { $0 == .unknown }.count + failedIDs.count)
            log.append("sides: left=\(counts.l) right=\(counts.r) unknown=\(counts.u) (unbalance is EXPECTED under rally scoring)")
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
        lastPointWinner: ServeSide? = nil
    ) -> [UUID: PointScore] {
        computeScoresWithTrace(points: points, serveSides: serveSides,
                               nextGameFirstServe: nextGameFirstServe,
                               firstServe: explicitFirstServe,
                               lastPointWinner: lastPointWinner).scores
    }

    /// Same computation, plus a per-play natural-language derivation trace
    /// ("how did this play get its winner") for the diagnostics log.
    static func computeScoresWithTrace(
        points: [GamePoint],
        serveSides: [UUID: ServeSide],
        nextGameFirstServe: ServeSide? = nil,
        firstServe explicitFirstServe: ServeSide? = nil,
        lastPointWinner: ServeSide? = nil
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
