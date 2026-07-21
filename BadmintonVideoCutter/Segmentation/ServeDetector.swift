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
        let pointData = points.map { (id: $0.id, start: $0.start) }
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

            for point in pointData {
                let t0 = CMTime(seconds: point.start + 0.1, preferredTimescale: 600)
                let t1 = CMTime(seconds: point.start + 0.5, preferredTimescale: 600)
                let t2 = CMTime(seconds: point.start + 0.9, preferredTimescale: 600)

                guard let img0 = try? generator.copyCGImage(at: t0, actualTime: nil),
                      let img1 = try? generator.copyCGImage(at: t1, actualTime: nil) else {
                    centroids.append((id: point.id, cx: 0.5, cy: 0.5))
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
                return (Dictionary(uniqueKeysWithValues: centroids.map { ($0.id, ServeSide.unknown) }), .horizontal, [:])
            }

            // Step 2: Determine which axis best separates the two players
            let xValues = centroids.map(\.cx)
            let yValues = centroids.map(\.cy)
            let xVariance = variance(xValues)
            let yVariance = variance(yValues)

            // Use the axis with more spread
            let axis: Axis = xVariance >= yVariance ? .horizontal : .vertical
            let values = axis == .horizontal ? xValues : yValues
            let sortedValues = values.sorted()
            let median = sortedValues[sortedValues.count / 2]

            // Step 3: Assign sides based on median split.
            // Points with centroid below median → left, above → right.
            // A small dead zone around the median handles ambiguous cases.
            let deadZone = 0.02  // 2% of frame dimension
            var results: [UUID: ServeSide] = [:]
            var margins: [UUID: Double] = [:]

            for (i, entry) in centroids.enumerated() {
                let val = values[i]
                margins[entry.id] = abs(val - median)
                if val < median - deadZone {
                    results[entry.id] = .left
                } else if val > median + deadZone {
                    results[entry.id] = .right
                } else {
                    results[entry.id] = .unknown
                }
            }

            return (results, axis, margins)
        }.value
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
        let activePoints = points.filter { $0.reviewStatus != .deleted }
        guard !activePoints.isEmpty else { return [:] }

        // Player A = the side that serves the game's FIRST point. Callers
        // should pass it explicitly so score columns and UI labels share one
        // anchor; the fallback infers from the earliest known side.
        let firstServe: ServeSide
        if let explicitFirstServe, explicitFirstServe != .unknown {
            firstServe = explicitFirstServe
        } else if let known = activePoints.first(where: { serveSides[$0.id] != nil && serveSides[$0.id] != .unknown }) {
            firstServe = serveSides[known.id]!
        } else {
            return [:]
        }

        var scoreA = 0
        var scoreB = 0
        var results: [UUID: PointScore] = [:]

        for i in 0..<activePoints.count {
            // Rally scoring: the winner of point N is exactly the side that
            // serves point N+1. Using only the NEXT serve (not the transition)
            // means one misdetected side corrupts one point, not two, and a
            // point whose own serve is unknown still scores correctly.
            let winnerSide: ServeSide
            if i < activePoints.count - 1 {
                winnerSide = serveSides[activePoints[i + 1].id] ?? .unknown
            } else {
                winnerSide = nextGameFirstServe ?? .unknown
            }

            if winnerSide != .unknown {
                if winnerSide == firstServe { scoreA += 1 } else { scoreB += 1 }
            } else if i == activePoints.count - 1 {
                // Last point with no following game: an explicit winner
                // override decides; else leader likely won; tie → server.
                let currentServe = serveSides[activePoints[i].id] ?? .unknown
                if let lastPointWinner, lastPointWinner != .unknown {
                    if lastPointWinner == firstServe { scoreA += 1 } else { scoreB += 1 }
                } else if scoreA != scoreB {
                    if scoreA > scoreB { scoreA += 1 } else { scoreB += 1 }
                } else if currentServe != .unknown, currentServe != firstServe {
                    scoreB += 1
                } else {
                    scoreA += 1
                }
            } else {
                // Next serve unknown mid-game — best guess: leader won.
                if scoreA >= scoreB { scoreA += 1 } else { scoreB += 1 }
            }

            results[activePoints[i].id] = PointScore(scoreA: scoreA, scoreB: scoreB)
        }

        return results
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
