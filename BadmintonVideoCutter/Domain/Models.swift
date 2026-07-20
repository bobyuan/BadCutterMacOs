import Foundation
import CoreGraphics

enum SegmentLabel: String, Codable, CaseIterable {
    case rally
    case betweenPoints
    case unknown
}

struct TimeSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var label: SegmentLabel
    var confidence: Double

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, label: SegmentLabel, confidence: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
        self.confidence = confidence
    }

    var duration: TimeInterval { max(0, end - start) }
}

struct VideoItem: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var url: URL
    var isSelected: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, displayName, url
    }

    init(id: UUID = UUID(), displayName: String, url: URL) {
        self.id = id
        self.displayName = displayName
        self.url = url
    }
}

// MARK: - Per-Video Analysis State

enum VideoAnalysisStatus {
    case notAnalyzed
    case analyzing
    case done
    case error(String)
}

struct VideoAnalysisResult {
    var status: VideoAnalysisStatus = .notAnalyzed
    var segments: [TimeSegment] = []
    var trimSegments: [TrimSegment] = []
    var games: [Game] = []
    var featureFrames: [FeatureFrame] = []
    var racketHits: [RacketHitEvent] = []
    var serveSides: [UUID: ServeDetector.ServeSide] = [:]
    var pointScores: [UUID: ServeDetector.PointScore] = [:]
    var analysisProgress: AnalysisProgress = AnalysisProgress()
    var videoMetadata: VideoMetadata?
    var calibrationFrames: [CalibrationFrame] = []
    var calibrationImages: [UUID: CGImage] = [:]
    // Session persistence (corrections ledger)
    var sessionBaseline: SessionBaseline?
    var sessionEvents: [SessionEvent] = []
    var audioSignals: AudioSignals = AudioSignals()
}

enum SensitivityPreset: String, CaseIterable, Codable, Identifiable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var rallyPercentile: Double {
        switch self {
        case .conservative: return 0.78
        case .balanced: return 0.68
        case .aggressive: return 0.58
        }
    }

    var motionWeight: Double {
        switch self {
        case .conservative: return 0.95
        case .balanced: return 0.90
        case .aggressive: return 0.80
        }
    }

    var audioWeight: Double {
        switch self {
        case .conservative: return 0.05
        case .balanced: return 0.10
        case .aggressive: return 0.20
        }
    }
}

struct AnalysisConfig: Codable {
    var minRallyDuration: TimeInterval = 1.0
    var minBetweenPointsDuration: TimeInterval = 3.0
    var flipHysteresisSeconds: TimeInterval = 1.5
    var rallyPercentile: Double = 0.68
    var motionWeight: Double = 0.90
    var audioWeight: Double = 0.10
    var preRollSeconds: TimeInterval = 2.5
    var postRollSeconds: TimeInterval = 1.5
    var maxExpectedRallyDuration: TimeInterval = 25.0
    var minDipDuration: TimeInterval = 3.0

    // Trajectory-based point splitting
    var minShuttleGap: TimeInterval = 1.5
    var maxShuttleGap: TimeInterval = 10.0
    var shuttleGapThreshold: Double = 0.3
    var positionDiscontinuityThreshold: Double = 0.3
    var minGapValidationScore: Int = 2

    // MARK: Shuttle-primary segmentation (was hardcoded in HybridSegmenter;
    // defaults exactly match the previous constants — pinned by the
    // segmentation + golden test suites)

    /// Fraction of frames that must have a shuttle position to trust the ML signal.
    var shuttlePositionRateThreshold: Double = 0.10
    /// Otsu threshold clamp for the bimodal combined-score distribution.
    var shuttleOtsuClampMin: Double = 0.25
    var shuttleOtsuClampMax: Double = 0.55
    /// Combined-score blend weights (presence / flight-motion / motion / audio).
    var shuttleBlendPresenceWeight: Double = 0.40
    var shuttleBlendFlightMotionWeight: Double = 0.30
    var shuttleBlendMotionWeight: Double = 0.20
    var shuttleBlendAudioWeight: Double = 0.10
    /// Post-processing constants in shuttle-primary mode.
    var shuttleMergeGap: TimeInterval = 0.5
    var shuttleMinBreak: TimeInterval = 1.5
    var shuttlePreRollSeconds: TimeInterval = 0.5
    var shuttlePostRollSeconds: TimeInterval = 0.5
    var shuttleMaxRallyDuration: TimeInterval = 15.0
    /// Rally fragments shorter than this are absorbed into breaks.
    var shuttleMinRallyAbsorb: TimeInterval = 3.0
    /// Final cleanup merge gap after fragment absorption.
    var finalMergeGap: TimeInterval = 2.0

    // Dip detection inside splitLongRallies: combined-score weights and the
    // duration-scaled sensitivity ladder (longer rallies split more eagerly).
    var dipPresenceWeight: Double = 0.35
    var dipFlightMotionWeight: Double = 0.30
    var dipMotionWeight: Double = 0.20
    var dipAudioWeight: Double = 0.15
    var dipThresholdStandard: Double = 0.50        // 15–20s rallies
    var dipMinDurationStandard: TimeInterval = 1.5
    var dipThresholdMedium: Double = 0.55          // 20–30s
    var dipMinDurationMedium: TimeInterval = 1.2
    var dipThresholdLong: Double = 0.60            // 30s+
    var dipMinDurationLong: TimeInterval = 1.0
}

// MARK: - Point Review & Game Structure

enum PointReviewStatus: String, Codable, CaseIterable {
    case confirmed
    case deleted
    case unreviewed
}

/// 👍/👎 highlight rating; persisted as `highlightRated` ledger events.
enum HighlightRating: String, Codable {
    case up
    case down
}

/// Why the user flagged a point (👎 menu). `notHighlight` is pure taste and
/// feeds the ranker's rating pool; every other reason is a *detection*
/// complaint that triggers an automatic boundary fix and stays out of the
/// taste pool (see D-008).
enum PointFeedbackReason: String, Codable, CaseIterable, Identifiable {
    case notHighlight
    case missedPointBefore
    case startsTooEarly
    case startsTooLate
    case endsTooEarly
    case endsTooLate
    case shouldSplit
    case notAPoint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notHighlight: return "Not highlight-worthy"
        case .missedPointBefore: return "Missed a point before this one"
        case .startsTooEarly: return "Starts too early (dead time before serve)"
        case .startsTooLate: return "Starts too late (play already going)"
        case .endsTooEarly: return "Ends too early (still active)"
        case .endsTooLate: return "Ends too late (dead time after rally)"
        case .shouldSplit: return "Two points merged — split it"
        case .notAPoint: return "Not a point at all"
        }
    }
}

/// Derived review state shown as a chip in the point list. `added` and
/// `edited` are ledger facts, not stored on the point.
enum ReviewChip: String {
    case auto
    case confirmed
    case edited
    case added
    case deleted
}

struct GamePoint: Identifiable, Codable, Equatable {
    let id: UUID
    var pointNumber: Int
    var rallySegment: TimeSegment
    var reviewStatus: PointReviewStatus

    init(id: UUID = UUID(), pointNumber: Int, rallySegment: TimeSegment, reviewStatus: PointReviewStatus = .unreviewed) {
        self.id = id
        self.pointNumber = pointNumber
        self.rallySegment = rallySegment
        self.reviewStatus = reviewStatus
    }

    var start: TimeInterval { rallySegment.start }
    var end: TimeInterval { rallySegment.end }
    var duration: TimeInterval { rallySegment.duration }
    var confidence: Double { rallySegment.confidence }

    static func == (lhs: GamePoint, rhs: GamePoint) -> Bool {
        lhs.id == rhs.id
    }
}

enum GameValidationStatus {
    case normal
    case tooFew(Int)
    case tooMany(Int)
}

struct Game: Identifiable, Codable {
    let id: UUID
    var gameNumber: Int
    var points: [GamePoint]
    var breakAfter: TimeSegment?

    init(id: UUID = UUID(), gameNumber: Int, points: [GamePoint], breakAfter: TimeSegment? = nil) {
        self.id = id
        self.gameNumber = gameNumber
        self.points = points
        self.breakAfter = breakAfter
    }

    var activePointCount: Int {
        points.filter { $0.reviewStatus != .deleted }.count
    }

    var validationStatus: GameValidationStatus {
        let count = activePointCount
        if count < 15 { return .tooFew(count) }
        if count > 50 { return .tooMany(count) }
        return .normal
    }

    var validationMessage: String? {
        switch validationStatus {
        case .normal: return nil
        case .tooFew(let count): return "Only \(count) points — possible missing detections"
        case .tooMany(let count): return "\(count) points — possible false positives"
        }
    }
}

// MARK: - Trim Segment

enum TrimReviewStatus: String, Codable, CaseIterable {
    case accepted
    case flagged
    case unreviewed
}

struct TrimSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var originalStart: TimeInterval
    var originalEnd: TimeInterval
    var reviewStatus: TrimReviewStatus

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, reviewStatus: TrimReviewStatus = .unreviewed) {
        self.id = id
        self.start = start
        self.end = end
        self.originalStart = start
        self.originalEnd = end
        self.reviewStatus = reviewStatus
    }

    var duration: TimeInterval { max(0, end - start) }
    var isModified: Bool { start != originalStart || end != originalEnd }

    static func == (lhs: TrimSegment, rhs: TrimSegment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hit Detection Model

enum HitModelStatus {
    case notTrained
    case training(progress: String)
    case trained(accuracy: Double, clipCount: Int)
    case failed(error: String)
}

// MARK: - Training Data Pool

struct TrainingDataManifest: Codable {
    var formatVersion: Int = 1
    var lastModified: Date = Date()
    var videos: [TrainingVideoEntry] = []
    var totalRallyClips: Int { videos.reduce(0) { $0 + $1.rallyClipCount } }
    var totalBackgroundClips: Int { videos.reduce(0) { $0 + $1.backgroundClipCount } }
}

struct TrainingVideoEntry: Codable, Identifiable {
    var id: String { clipPrefix }
    var videoFileName: String
    var addedDate: Date
    var rallyClipCount: Int
    var backgroundClipCount: Int
    var clipPrefix: String
}

enum TrainingPoolStatus {
    case empty
    case hasData(manifest: TrainingDataManifest)
    case saving(progress: String)
}

extension JSONDecoder {
    static var manifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var manifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - Audio Features

struct AudioFeature: Sendable {
    var timestamp: TimeInterval
    var rmsEnergy: Double
    var isOnset: Bool
    var rallyScore: Double
}

struct RacketHitEvent: Identifiable, Codable, Sendable {
    let id: UUID
    var timestamp: TimeInterval
    var intensity: Double

    init(id: UUID = UUID(), timestamp: TimeInterval, intensity: Double) {
        self.id = id
        self.timestamp = timestamp
        self.intensity = intensity
    }
}

// MARK: - Analysis Progress

enum AnalysisStage: String, CaseIterable, Sendable {
    case idle = "Idle"
    case extracting = "Extracting Features"
    case finalizing = "Finalizing"
    case complete = "Complete"
}

struct AnalysisProgress: Sendable {
    var stage: AnalysisStage = .idle
    var audioProgress: Double = 0.0
    var videoProgress: Double = 0.0
    var ralliesFound: Int = 0
    var estimatedTrimPercent: Double = 0.0
    var elapsedSeconds: TimeInterval = 0

    var overallProgress: Double {
        switch stage {
        case .idle: return 0
        case .extracting:
            // Audio is ~25% of work, video is ~75%
            return (audioProgress * 0.25 + videoProgress * 0.75) * 0.95
        case .finalizing: return 0.95
        case .complete: return 1.0
        }
    }
}

// MARK: - Video Metadata

struct VideoMetadata: Sendable {
    var duration: TimeInterval
    var resolution: CGSize
    var codec: String
    var frameRate: Double
    var fileSize: Int64
    var hasAudio: Bool

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedResolution: String {
        "\(Int(resolution.width))x\(Int(resolution.height))"
    }
}

// MARK: - Removal Statistics

struct RemovalStatistics {
    var originalDuration: TimeInterval
    var keptDuration: TimeInterval
    var removedDuration: TimeInterval
    var trimCount: Int
    var rallyCount: Int
    var trimDurations: [TimeInterval]
    var rallyDurations: [TimeInterval]

    var trimPercent: Double {
        guard originalDuration > 0 else { return 0 }
        return (removedDuration / originalDuration) * 100
    }

    var keptPercent: Double {
        guard originalDuration > 0 else { return 0 }
        return (keptDuration / originalDuration) * 100
    }

    static func compute(
        segments: [TimeSegment],
        trimSegments: [TrimSegment],
        videoDuration: TimeInterval
    ) -> RemovalStatistics {
        let rallies = segments.filter { $0.label == .rally }
        let acceptedTrims = trimSegments.filter { $0.reviewStatus != .flagged }
        let removedDuration = acceptedTrims.reduce(0.0) { $0 + $1.duration }
        let keptDuration = videoDuration - removedDuration

        return RemovalStatistics(
            originalDuration: videoDuration,
            keptDuration: keptDuration,
            removedDuration: removedDuration,
            trimCount: acceptedTrims.count,
            rallyCount: rallies.count,
            trimDurations: acceptedTrims.map(\.duration),
            rallyDurations: rallies.map(\.duration)
        )
    }
}

// MARK: - Export Configuration

enum TransitionStyle: String, CaseIterable, Identifiable {
    case cut = "Hard Cut"
    case crossfade = "Crossfade"

    var id: String { rawValue }
}

/// How the highlight reel picks its points (DESIGN §3.3).
enum HighlightSelection: Equatable {
    case topPercent(Double)
    case topMinutes(Double)
    case threshold(Double)
}

/// Export is a set of selection policies, not a mode (DESIGN §3.3).
struct ExportPlan {
    enum Reel: String, CaseIterable, Identifiable {
        case scoring        // all active points
        case highlights     // best points by highlight score

        var id: String { rawValue }
    }

    var reels: Set<Reel> = [.scoring]
    var highlightSelection: HighlightSelection = .topPercent(20)
    var individualClips: Bool = false
    var scoreOverlay: Bool = false          // v2.1
    var transition: TransitionStyle = .cut  // .crossfade v2.1
    var matchSourceFormat: Bool = true
}

/// One rendered export: a reel or an individual clip.
struct ExportOutput: Identifiable {
    let id = UUID()
    var label: String
    var url: URL
    var duration: TimeInterval
    var fileSize: Int64
}

// MARK: - Shuttlecock Calibration

enum CalibrationStatus: String, Codable, CaseIterable {
    case unlabeled
    case labeled      // User placed rectangle on shuttlecock
    case notVisible   // User confirmed bird is not visible in this frame
}

struct CalibrationFrame: Identifiable, Codable {
    let id: UUID
    var timestamp: TimeInterval
    var status: CalibrationStatus
    /// Normalized 0-1 position of shuttlecock center (nil if not labeled)
    var shuttlecockPosition: CGPoint?
    /// Normalized 0-1 size of the bounding box
    var boxSize: CGSize

    init(id: UUID = UUID(), timestamp: TimeInterval,
         boxSize: CGSize = CGSize(width: 0.017, height: 0.017)) {
        self.id = id
        self.timestamp = timestamp
        self.status = .unlabeled
        self.shuttlecockPosition = nil
        self.boxSize = boxSize
    }
}

// MARK: - Timeline Viewport

struct TimelineViewport {
    var visibleStart: TimeInterval = 0
    var visibleEnd: TimeInterval = 60
    var zoom: Double = 1.0

    var visibleDuration: TimeInterval { visibleEnd - visibleStart }

    mutating func zoomIn(around time: TimeInterval) {
        let newZoom = min(zoom * 1.5, 50.0)
        let ratio = newZoom / zoom
        let offset = time - visibleStart
        visibleStart = time - offset / ratio
        visibleEnd = visibleStart + visibleDuration / ratio
        zoom = newZoom
    }

    mutating func zoomOut(around time: TimeInterval) {
        let newZoom = max(zoom / 1.5, 1.0)
        let ratio = newZoom / zoom
        let offset = time - visibleStart
        visibleStart = time - offset / ratio
        visibleEnd = visibleStart + visibleDuration / ratio
        zoom = newZoom
    }
}
