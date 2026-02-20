import Foundation

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

    init(id: UUID = UUID(), displayName: String, url: URL) {
        self.id = id
        self.displayName = displayName
        self.url = url
    }
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
        case .conservative: return 0.75
        case .balanced: return 0.65
        case .aggressive: return 0.55
        }
    }

    var audioWeight: Double {
        switch self {
        case .conservative: return 0.25
        case .balanced: return 0.35
        case .aggressive: return 0.45
        }
    }
}

struct AnalysisConfig: Codable {
    var minRallyDuration: TimeInterval = 1.0
    var minBetweenPointsDuration: TimeInterval = 1.5
    var flipHysteresisSeconds: TimeInterval = 1.0
    var rallyPercentile: Double = 0.68
    var motionWeight: Double = 0.65
    var audioWeight: Double = 0.35
    var preRollSeconds: TimeInterval = 1.5
    var maxExpectedRallyDuration: TimeInterval = 25.0
    var minDipDuration: TimeInterval = 1.5
}

// MARK: - Point Review & Game Structure

enum PointReviewStatus: String, Codable, CaseIterable {
    case confirmed
    case deleted
    case unreviewed
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

enum ExportMode: String, CaseIterable, Identifiable {
    case singleTrimmed = "Single Trimmed Video"
    case individualRallies = "Individual Rally Clips"
    case both = "Both"

    var id: String { rawValue }
}

enum TransitionStyle: String, CaseIterable, Identifiable {
    case cut = "Hard Cut"
    case crossfade = "Crossfade"

    var id: String { rawValue }
}

struct ExportConfig {
    var mode: ExportMode = .singleTrimmed
    var transition: TransitionStyle = .cut
    var matchSourceFormat: Bool = true
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
