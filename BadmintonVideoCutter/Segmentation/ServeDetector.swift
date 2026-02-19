import Foundation
import AVFoundation
import CoreGraphics

final class ServeDetector {

    enum ServeSide: String, Codable, Sendable {
        case left
        case right
        case unknown
    }

    struct PointScore: Sendable {
        var scoreA: Int  // First server's score
        var scoreB: Int  // Other player's score

        var display: String {
            "\(scoreA):\(scoreB)"
        }
    }

    /// Detect which side of the court serves each point by analyzing
    /// left vs right motion asymmetry at the start of each rally.
    /// The serving player initiates the first significant motion.
    static func detectServes(videoURL: URL, points: [GamePoint]) async -> [UUID: ServeSide] {
        let pointData = points.map { (id: $0.id, start: $0.start) }

        return await Task.detached {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            var results: [UUID: ServeSide] = [:]

            for point in pointData {
                // Grab two frames: just after rally start and 0.5s later
                // The serve motion happens in this window
                let t0 = CMTime(seconds: point.start + 0.1, preferredTimescale: 600)
                let t1 = CMTime(seconds: point.start + 0.6, preferredTimescale: 600)

                guard let img0 = try? generator.copyCGImage(at: t0, actualTime: nil),
                      let img1 = try? generator.copyCGImage(at: t1, actualTime: nil) else {
                    results[point.id] = .unknown
                    continue
                }

                let (leftMotion, rightMotion) = computeHalfMotion(img0, img1)

                let total = leftMotion + rightMotion
                guard total > 100 else {
                    // Not enough motion detected
                    results[point.id] = .unknown
                    continue
                }

                let leftRatio = leftMotion / total
                if leftRatio > 0.58 {
                    results[point.id] = .left
                } else if leftRatio < 0.42 {
                    results[point.id] = .right
                } else {
                    results[point.id] = .unknown
                }
            }

            return results
        }.value
    }

    // MARK: - Motion Analysis

    /// Compare two frames and return total motion in left vs right halves.
    private static func computeHalfMotion(_ img1: CGImage, _ img2: CGImage) -> (left: Double, right: Double) {
        let width = 160
        let height = 90

        guard let data1 = renderToPixels(img1, width: width, height: height),
              let data2 = renderToPixels(img2, width: width, height: height) else {
            return (0, 0)
        }

        let halfWidth = width / 2
        var leftSum: Double = 0
        var rightSum: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let diff = abs(Int(data1[idx]) - Int(data2[idx])) +
                           abs(Int(data1[idx + 1]) - Int(data2[idx + 1])) +
                           abs(Int(data1[idx + 2]) - Int(data2[idx + 2]))

                if x < halfWidth {
                    leftSum += Double(diff)
                } else {
                    rightSum += Double(diff)
                }
            }
        }

        return (leftSum, rightSum)
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

    // MARK: - Score Computation

    /// Compute running scores for points within a single game.
    /// Player A = whoever serves the first point of the game.
    /// Rule: winner of point N serves point N+1.
    /// So if same side serves consecutive points → server won.
    /// If side changes → receiver won.
    static func computeScores(
        points: [GamePoint],
        serveSides: [UUID: ServeSide],
        nextGameFirstServe: ServeSide? = nil
    ) -> [UUID: PointScore] {
        let activePoints = points.filter { $0.reviewStatus != .deleted }
        guard !activePoints.isEmpty else { return [:] }

        // Determine player A = the side that serves first in this game
        let firstServe = serveSides[activePoints[0].id] ?? .unknown
        guard firstServe != .unknown else { return [:] }

        var scoreA = 0
        var scoreB = 0
        var results: [UUID: PointScore] = [:]

        for i in 0..<activePoints.count {
            let currentServe = serveSides[activePoints[i].id] ?? .unknown

            // Determine who won this point by checking who serves next
            let nextServe: ServeSide
            if i < activePoints.count - 1 {
                nextServe = serveSides[activePoints[i + 1].id] ?? .unknown
            } else if let ngs = nextGameFirstServe {
                // Last point of game: use first serve of next game
                // (winner of game serves first in next game)
                nextServe = ngs
            } else {
                // Last point of match — show score without resolving
                results[activePoints[i].id] = PointScore(scoreA: scoreA, scoreB: scoreB)
                continue
            }

            if currentServe != .unknown && nextServe != .unknown {
                let serverIsA = (currentServe == firstServe)
                if currentServe == nextServe {
                    // Server won this point
                    if serverIsA { scoreA += 1 } else { scoreB += 1 }
                } else {
                    // Receiver won this point
                    if serverIsA { scoreB += 1 } else { scoreA += 1 }
                }
            }

            results[activePoints[i].id] = PointScore(scoreA: scoreA, scoreB: scoreB)
        }

        return results
    }
}
