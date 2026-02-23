import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - Video State
    @Published var videoItems: [VideoItem] = []
    @Published var currentAssetURL: URL?
    @Published var player: AVPlayer?
    @Published var videoMetadata: VideoMetadata?

    // MARK: - Analysis State
    @Published var segments: [TimeSegment] = []
    @Published var trimSegments: [TrimSegment] = []
    @Published var games: [Game] = []
    @Published var featureFrames: [FeatureFrame] = []
    @Published var racketHits: [RacketHitEvent] = []
    @Published var analysisProgress = AnalysisProgress()
    @Published var sensitivity: SensitivityPreset = .aggressive
    @Published var isAnalyzing = false

    // MARK: - Serve & Score State
    @Published var serveSides: [UUID: ServeDetector.ServeSide] = [:]
    @Published var pointScores: [UUID: ServeDetector.PointScore] = [:]

    // MARK: - Calibration State
    @Published var calibrationFrames: [CalibrationFrame] = []
    @Published var selectedCalibrationFrameID: UUID?
    @Published var calibrationImages: [UUID: CGImage] = [:]

    // MARK: - Hit Model State
    @Published var hitModelStatus: HitModelStatus = .notTrained

    var hitModelURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        let modelURL = modelDir.appendingPathComponent("hit_classifier.mlmodelc")
        return FileManager.default.fileExists(atPath: modelURL.path) ? modelURL : nil
    }

    /// URL for the TrackNetV3 shuttlecock detection CoreML model.
    /// Checks the app bundle first (Xcode compiles .mlpackage → .mlmodelc at build time),
    /// then falls back to Application Support for manually placed models.
    var shuttlecockModelURL: URL? {
        // 1. App bundle (bundled at build time — Xcode compiles .mlpackage → .mlmodelc)
        if let bundled = Bundle.main.url(forResource: "TrackNetV3", withExtension: "mlmodelc") {
            return bundled
        }
        // 2. Fallback: Application Support (manually placed)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        let compiled = modelDir.appendingPathComponent("TrackNetV3.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = modelDir.appendingPathComponent("TrackNetV3.mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        return nil
    }

    var hasShuttlecockModel: Bool {
        shuttlecockModelURL != nil
    }

    private var hitModelOutputURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        return modelDir.appendingPathComponent("hit_classifier.mlmodelc")
    }

    // MARK: - Export State
    @Published var exportConfig = ExportConfig()
    @Published var isExporting = false

    // MARK: - UI State
    @Published var statusMessage: String?
    @Published var lastErrorMessage: String?
    @Published var isShowingFileImporter = false

    private let exporter = VideoExporter()

    init() {
        // Check if a trained model already exists
        if FileManager.default.fileExists(atPath: hitModelOutputURL.path) {
            hitModelStatus = .trained(accuracy: 0, clipCount: 0)
        }
    }

    // MARK: - Computed Properties

    var removalStatistics: RemovalStatistics? {
        guard let meta = videoMetadata, !segments.isEmpty else { return nil }
        return RemovalStatistics.compute(
            segments: segments,
            trimSegments: trimSegments,
            videoDuration: meta.duration
        )
    }

    var effectiveKeptSegments: [TimeSegment] {
        // When games exist, use game-based filtering
        if !games.isEmpty {
            return games.flatMap(\.points)
                .filter { $0.reviewStatus != .deleted }
                .map(\.rallySegment)
                .sorted { $0.start < $1.start }
        }

        // Fallback to old behavior
        let flaggedTrims = Set(trimSegments.filter { $0.reviewStatus == .flagged }.map(\.id))
        guard !flaggedTrims.isEmpty else {
            return segments.filter { $0.label == .rally }
        }

        var kept = segments.filter { $0.label == .rally }
        for trim in trimSegments where trim.reviewStatus == .flagged {
            kept.append(TimeSegment(
                start: trim.start,
                end: trim.end,
                label: .rally,
                confidence: 0.5
            ))
        }
        return kept.sorted { $0.start < $1.start }
    }

    // MARK: - Video Loading

    func loadVideo(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let item = VideoItem(displayName: url.lastPathComponent, url: url)
        videoItems.append(item)
        currentAssetURL = url
        player = AVPlayer(url: url)
        segments = []
        trimSegments = []
        games = []
        featureFrames = []
        racketHits = []
        calibrationFrames = []
        selectedCalibrationFrameID = nil
        calibrationImages = [:]
        calibrationSessionID = ""
        analysisProgress = AnalysisProgress()
        statusMessage = "Loaded \(url.lastPathComponent)"
        lastErrorMessage = nil

        Task { await probeMetadata(url: url) }
        loadCalibrationData()
    }

    private func probeMetadata(url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            var resolution = CGSize.zero
            var frameRate: Double = 30
            var codec = "Unknown"

            if let vTrack = videoTracks.first {
                resolution = try await vTrack.load(.naturalSize)
                frameRate = try await Double(vTrack.load(.nominalFrameRate))
                let descriptions = try await vTrack.load(.formatDescriptions)
                if let desc = descriptions.first {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    codec = fourCCToString(mediaSubType)
                }
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            videoMetadata = VideoMetadata(
                duration: duration,
                resolution: resolution,
                codec: codec,
                frameRate: frameRate,
                fileSize: fileSize,
                hasAudio: !audioTracks.isEmpty
            )
        } catch {
            lastErrorMessage = "Failed to probe metadata: \(error.localizedDescription)"
        }
    }

    private func fourCCToString(_ code: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars)
    }

    // MARK: - Analysis

    private var analysisStartTime: Date?
    private var elapsedTimer: Timer?

    func analyzeCurrentVideo() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        isAnalyzing = true
        statusMessage = "Analyzing..."
        lastErrorMessage = nil
        analysisProgress = AnalysisProgress(stage: .extracting)
        analysisStartTime = Date()

        // Timer to update elapsed seconds every 0.5s
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.analysisStartTime else { return }
                self.analysisProgress.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }

        Task {
            do {
                let config = AnalysisConfig(
                    rallyPercentile: sensitivity.rallyPercentile,
                    motionWeight: sensitivity.motionWeight,
                    audioWeight: sensitivity.audioWeight
                )

                analysisProgress.stage = .extracting
                let extractor = BasicFeatureExtractor()
                let callbacks = BasicFeatureExtractor.ProgressCallbacks(
                    onAudioProgress: { [weak self] p in
                        self?.analysisProgress.audioProgress = p
                    },
                    onVideoProgress: { [weak self] p in
                        self?.analysisProgress.videoProgress = p
                    }
                )
                let frames = try await extractor.extractFeatures(from: url, mlModelURL: hitModelURL, progress: callbacks, shuttlecockModelURL: shuttlecockModelURL)
                self.featureFrames = frames

                analysisProgress.stage = .finalizing
                let classifier = HybridSegmenter()
                let rawSegments = classifier.classify(frames: frames, config: config)
                let processed = classifier.postProcess(segments: rawSegments, frames: frames, config: config)
                let refined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
                self.segments = refined

                deriveGameStructure()
                deriveTrimSegments()
                detectServesAndScores()

                let rallyCount = refined.filter { $0.label == .rally }.count
                let elapsed = Date().timeIntervalSince(analysisStartTime ?? Date())
                let mlStatus = self.hasShuttlecockModel ? " [ML]" : ""
                analysisProgress = AnalysisProgress(
                    stage: .complete,
                    audioProgress: 1.0,
                    videoProgress: 1.0,
                    ralliesFound: rallyCount,
                    estimatedTrimPercent: removalStatistics?.trimPercent ?? 0,
                    elapsedSeconds: elapsed
                )
                let gameCount = games.count
                statusMessage = "Analysis complete\(mlStatus): \(rallyCount) points in \(gameCount) game\(gameCount == 1 ? "" : "s") (\(formatElapsed(elapsed)))"
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            isAnalyzing = false
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        if t < 60 {
            return String(format: "%.1fs", t)
        }
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Game Structure

    func deriveGameStructure() {
        games = GameDetector.detectGames(from: segments, featureFrames: featureFrames)
    }

    func setPointReviewStatus(pointID: UUID, status: PointReviewStatus) {
        for gameIdx in games.indices {
            if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                games[gameIdx].points[pointIdx].reviewStatus = status
                deriveTrimSegments()
                computeAllScores()
                return
            }
        }
    }

    // MARK: - Serve Detection & Scoring

    func detectServesAndScores() {
        guard let url = currentAssetURL, !games.isEmpty else { return }
        let allPoints = games.flatMap(\.points)

        Task {
            let sides = await ServeDetector.detectServes(videoURL: url, points: allPoints)
            self.serveSides = sides
            computeAllScores()
        }
    }

    func computeAllScores() {
        var allScores: [UUID: ServeDetector.PointScore] = [:]

        for (gameIdx, game) in games.enumerated() {
            // For the last point of this game, check first serve of next game
            let nextGameFirstServe: ServeDetector.ServeSide?
            if gameIdx < games.count - 1 {
                let nextGameActivePoint = games[gameIdx + 1].points.first { $0.reviewStatus != .deleted }
                nextGameFirstServe = nextGameActivePoint.flatMap { serveSides[$0.id] }
            } else {
                nextGameFirstServe = nil
            }

            let scores = ServeDetector.computeScores(
                points: game.points,
                serveSides: serveSides,
                nextGameFirstServe: nextGameFirstServe
            )
            allScores.merge(scores) { _, new in new }
        }

        pointScores = allScores
    }

    // MARK: - Trim Segments

    func deriveTrimSegments() {
        if !games.isEmpty {
            // Derive trims from gaps between active points
            let activeSegments = games.flatMap(\.points)
                .filter { $0.reviewStatus != .deleted }
                .map(\.rallySegment)
                .sorted { $0.start < $1.start }

            let totalDuration = videoMetadata?.duration ?? activeSegments.last?.end ?? 0
            var trims: [TrimSegment] = []

            for i in 0..<activeSegments.count {
                let gapStart: TimeInterval
                let gapEnd: TimeInterval

                if i == 0 {
                    // Gap before first rally
                    if activeSegments[i].start > 0.1 {
                        trims.append(TrimSegment(start: 0, end: activeSegments[i].start))
                    }
                }

                if i < activeSegments.count - 1 {
                    gapStart = activeSegments[i].end
                    gapEnd = activeSegments[i + 1].start
                    if gapEnd - gapStart > 0.1 {
                        trims.append(TrimSegment(start: gapStart, end: gapEnd))
                    }
                } else {
                    // Gap after last rally
                    if totalDuration - activeSegments[i].end > 0.1 {
                        trims.append(TrimSegment(start: activeSegments[i].end, end: totalDuration))
                    }
                }
            }
            trimSegments = trims
        } else {
            trimSegments = segments
                .filter { $0.label == .betweenPoints }
                .map { seg in
                    TrimSegment(start: seg.start, end: seg.end)
                }
        }
    }

    func updateTrimBoundary(trimID: UUID, newStart: TimeInterval? = nil, newEnd: TimeInterval? = nil) {
        guard let index = trimSegments.firstIndex(where: { $0.id == trimID }) else { return }
        let duration = videoMetadata?.duration ?? .infinity

        if let newStart = newStart {
            trimSegments[index].start = max(0, min(newStart, trimSegments[index].end - 0.1))
        }
        if let newEnd = newEnd {
            trimSegments[index].end = min(duration, max(newEnd, trimSegments[index].start + 0.1))
        }
    }

    /// Find the point adjacent to a trim edge.
    /// Leading edge → the point whose .end borders the trim's start.
    /// Trailing edge → the point whose .start borders the trim's end.
    func adjacentPointForTrim(trimID: UUID, edge: HorizontalEdge) -> UUID? {
        guard let trim = trimSegments.first(where: { $0.id == trimID }) else { return nil }

        let activePoints = games.flatMap(\.points)
            .filter { $0.reviewStatus != .deleted }
            .sorted { $0.start < $1.start }

        if edge == .leading {
            // Left edge of trim → find point whose end is closest to trim.start
            return activePoints.last(where: { $0.end <= trim.start + 0.5 })?.id
        } else {
            // Right edge of trim → find point whose start is closest to trim.end
            return activePoints.first(where: { $0.start >= trim.end - 0.5 })?.id
        }
    }

    /// Update a point's rally segment start or end time.
    func updatePointBoundary(pointID: UUID, newStart: TimeInterval? = nil, newEnd: TimeInterval? = nil) {
        let duration = videoMetadata?.duration ?? .infinity
        for gameIdx in games.indices {
            if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                if let ns = newStart {
                    let minStart = max(0, ns)
                    let maxStart = games[gameIdx].points[pointIdx].rallySegment.end - 0.5
                    games[gameIdx].points[pointIdx].rallySegment.start = min(minStart, maxStart)
                }
                if let ne = newEnd {
                    let maxEnd = min(duration, ne)
                    let minEnd = games[gameIdx].points[pointIdx].rallySegment.start + 0.5
                    games[gameIdx].points[pointIdx].rallySegment.end = max(maxEnd, minEnd)
                }
                return
            }
        }
    }

    // MARK: - Calibration Persistence

    /// Unique session ID for each calibration run, so multiple sessions don't overwrite.
    private var calibrationSessionID: String = ""

    /// Root directory for all calibration sessions of a video:
    /// AppSupport/BadmintonVideoCutter/calibration/<video-filename>/
    private func calibrationRootDirectory(for videoURL: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BadmintonVideoCutter")
            .appendingPathComponent("calibration")
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent)
    }

    /// Directory for the current calibration session:
    /// .../calibration/<video-filename>/<sessionID>/
    private func calibrationSessionDirectory(for videoURL: URL) -> URL {
        calibrationRootDirectory(for: videoURL).appendingPathComponent(calibrationSessionID)
    }

    /// Save calibration frames metadata (JSON) and frame images (PNG) to disk.
    func saveCalibrationData() {
        guard let url = currentAssetURL, !calibrationFrames.isEmpty else { return }
        if calibrationSessionID.isEmpty {
            calibrationSessionID = Self.makeSessionID()
        }

        let dir = calibrationSessionDirectory(for: url)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Save metadata JSON
        let metadataURL = dir.appendingPathComponent("calibration.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(calibrationFrames) {
            try? data.write(to: metadataURL)
        }

        // Save frame images as PNG
        let imagesDir = dir.appendingPathComponent("frames")
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        for frame in calibrationFrames {
            guard let cgImage = calibrationImages[frame.id] else { continue }
            let imageURL = imagesDir.appendingPathComponent("\(frame.id.uuidString).png")
            guard !fm.fileExists(atPath: imageURL.path) else { continue }
            if let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    private static func makeSessionID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// Load the most recent calibration session for the current video.
    /// Returns true if calibration data was loaded.
    @discardableResult
    func loadCalibrationData() -> Bool {
        guard let url = currentAssetURL else { return false }

        let rootDir = calibrationRootDirectory(for: url)
        let fm = FileManager.default

        // Find most recent session subdirectory (sorted by name = sorted by date)
        guard let sessions = try? fm.contentsOfDirectory(atPath: rootDir.path),
              let latestSession = sessions.sorted().last else { return false }

        calibrationSessionID = latestSession
        let dir = rootDir.appendingPathComponent(latestSession)
        let metadataURL = dir.appendingPathComponent("calibration.json")

        guard let data = try? Data(contentsOf: metadataURL),
              let frames = try? JSONDecoder().decode([CalibrationFrame].self, from: data) else {
            return false
        }

        calibrationFrames = frames
        selectedCalibrationFrameID = frames.first?.id

        // Load frame images
        let imagesDir = dir.appendingPathComponent("frames")
        for frame in frames {
            let imageURL = imagesDir.appendingPathComponent("\(frame.id.uuidString).png")
            if let dataProvider = CGDataProvider(url: imageURL as CFURL),
               let cgImage = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                calibrationImages[frame.id] = cgImage
            }
        }

        let labeledCount = frames.filter { $0.status != .unlabeled }.count
        if labeledCount > 0 {
            statusMessage = "Loaded \(labeledCount)/\(frames.count) calibration labels"
        }
        return true
    }

    // MARK: - Calibration

    /// Select ~20 representative frames from the analyzed featureFrames.
    func generateCalibrationFrames() {
        guard !featureFrames.isEmpty else { return }

        // New session ID so previous calibration data is preserved
        calibrationSessionID = Self.makeSessionID()

        let sorted = featureFrames.sorted { $0.motionScore < $1.motionScore }
        let count = sorted.count
        var selected: [TimeInterval] = []

        // ~8 from top 20% (high motion — bird likely in flight)
        let highStart = Int(Double(count) * 0.8)
        let highFrames = Array(sorted[highStart...])
        let highStep = max(1, highFrames.count / 8)
        for i in stride(from: 0, to: highFrames.count, by: highStep) {
            selected.append(highFrames[i].timestamp)
            if selected.count >= 8 { break }
        }

        // ~5 from bottom 20% (low motion — bird on ground or absent)
        let lowEnd = Int(Double(count) * 0.2)
        let lowFrames = Array(sorted[..<lowEnd])
        let lowStep = max(1, lowFrames.count / 5)
        for i in stride(from: 0, to: lowFrames.count, by: lowStep) {
            selected.append(lowFrames[i].timestamp)
            if selected.count >= 13 { break }
        }

        // ~4 near rally start/end boundaries (transition moments)
        let rallies = segments.filter { $0.label == .rally }
        var transitionTimes: [TimeInterval] = []
        for rally in rallies {
            transitionTimes.append(rally.start + 0.5)
            transitionTimes.append(max(0, rally.end - 0.5))
        }
        transitionTimes.shuffle()
        for t in transitionTimes.prefix(4) {
            selected.append(t)
        }

        // ~3 evenly spaced across the video duration
        if let duration = videoMetadata?.duration, duration > 0 {
            for i in 1...3 {
                let t = duration * Double(i) / 4.0
                selected.append(t)
            }
        }

        // Deduplicate: ensure no two frames within 3 seconds of each other
        var deduped: [TimeInterval] = []
        let sortedSelected = selected.sorted()
        for t in sortedSelected {
            if deduped.allSatisfy({ abs($0 - t) >= 3.0 }) {
                deduped.append(t)
            }
        }

        // Cap at 20 and sort by timestamp
        let finalTimes = Array(deduped.prefix(20)).sorted()

        calibrationFrames = finalTimes.map { CalibrationFrame(timestamp: $0) }
        selectedCalibrationFrameID = calibrationFrames.first?.id

        // Extract images for all frames, then persist
        Task {
            for frame in calibrationFrames {
                await extractCalibrationImage(for: frame)
            }
            saveCalibrationData()
        }
    }

    /// Extract CGImage for a CalibrationFrame using AVAssetImageGenerator.
    func extractCalibrationImage(for frame: CalibrationFrame) async {
        guard let url = currentAssetURL else { return }

        let frameID = frame.id
        let timestamp = frame.timestamp

        let image: CGImage? = await Task.detached {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            let cmTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            return try? generator.copyCGImage(at: cmTime, actualTime: nil)
        }.value

        if let image {
            calibrationImages[frameID] = image
        }
    }

    /// Update a frame's label with a position (marks as labeled).
    func setCalibrationLabel(frameID: UUID, position: CGPoint?) {
        guard let idx = calibrationFrames.firstIndex(where: { $0.id == frameID }) else { return }
        if let pos = position {
            calibrationFrames[idx].status = .labeled
            calibrationFrames[idx].shuttlecockPosition = pos
        } else {
            calibrationFrames[idx].status = .unlabeled
            calibrationFrames[idx].shuttlecockPosition = nil
        }
        saveCalibrationData()
    }

    /// Re-run analysis using calibration priors to improve shuttlecock detection.
    func reAnalyzeWithCalibration() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        let labeledFrames = calibrationFrames.filter { $0.status == .labeled && $0.shuttlecockPosition != nil }
        guard !labeledFrames.isEmpty else {
            lastErrorMessage = "Label at least one calibration frame first."
            return
        }

        isAnalyzing = true
        statusMessage = "Re-analyzing with calibration..."
        lastErrorMessage = nil
        analysisProgress = AnalysisProgress(stage: .extracting)
        analysisStartTime = Date()

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.analysisStartTime else { return }
                self.analysisProgress.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }

        let priors = labeledFrames.map { frame in
            BasicFeatureExtractor.CalibrationPrior(
                timestamp: frame.timestamp,
                position: frame.shuttlecockPosition!
            )
        }

        Task {
            do {
                let config = AnalysisConfig(
                    rallyPercentile: sensitivity.rallyPercentile,
                    motionWeight: sensitivity.motionWeight,
                    audioWeight: sensitivity.audioWeight
                )

                analysisProgress.stage = .extracting
                let extractor = BasicFeatureExtractor()
                let callbacks = BasicFeatureExtractor.ProgressCallbacks(
                    onAudioProgress: { [weak self] p in
                        self?.analysisProgress.audioProgress = p
                    },
                    onVideoProgress: { [weak self] p in
                        self?.analysisProgress.videoProgress = p
                    }
                )
                let frames = try await extractor.extractFeatures(from: url, mlModelURL: hitModelURL, progress: callbacks, calibrationPriors: priors, shuttlecockModelURL: shuttlecockModelURL)
                self.featureFrames = frames

                analysisProgress.stage = .finalizing
                let classifier = HybridSegmenter()
                let rawSegments = classifier.classify(frames: frames, config: config)
                let processed = classifier.postProcess(segments: rawSegments, frames: frames, config: config)
                let refined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
                self.segments = refined

                deriveGameStructure()
                deriveTrimSegments()
                detectServesAndScores()

                let rallyCount = refined.filter { $0.label == .rally }.count
                let elapsed = Date().timeIntervalSince(analysisStartTime ?? Date())
                let mlStatus = self.hasShuttlecockModel ? " [ML]" : ""
                analysisProgress = AnalysisProgress(
                    stage: .complete,
                    audioProgress: 1.0,
                    videoProgress: 1.0,
                    ralliesFound: rallyCount,
                    estimatedTrimPercent: removalStatistics?.trimPercent ?? 0,
                    elapsedSeconds: elapsed
                )
                let gameCount = games.count
                statusMessage = "Calibrated re-analysis complete\(mlStatus): \(rallyCount) points in \(gameCount) game\(gameCount == 1 ? "" : "s") (\(formatElapsed(elapsed)))"
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            isAnalyzing = false
        }
    }

    /// Mark a frame as "bird not visible".
    func setCalibrationNotVisible(frameID: UUID) {
        guard let idx = calibrationFrames.firstIndex(where: { $0.id == frameID }) else { return }
        calibrationFrames[idx].status = .notVisible
        calibrationFrames[idx].shuttlecockPosition = nil
        saveCalibrationData()
    }

    // MARK: - Hit Model Training

    func trainHitDetector() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        guard !games.isEmpty else {
            lastErrorMessage = "Analyze a video and review points before training."
            return
        }

        hitModelStatus = .training(progress: "Starting...")

        Task {
            do {
                let result = try await HitModelTrainer.train(
                    videoURL: url,
                    games: games,
                    featureFrames: self.featureFrames,
                    outputModelURL: hitModelOutputURL,
                    progress: { [weak self] msg in
                        Task { @MainActor [weak self] in
                            self?.hitModelStatus = .training(progress: msg)
                        }
                    }
                )
                hitModelStatus = .trained(accuracy: result.accuracy, clipCount: result.clipCount)
                statusMessage = String(format: "Model trained: %.0f%% accuracy from %d clips", result.accuracy * 100, result.clipCount)
            } catch {
                hitModelStatus = .failed(error: error.localizedDescription)
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func deleteHitModel() {
        try? FileManager.default.removeItem(at: hitModelOutputURL)
        hitModelStatus = .notTrained
        statusMessage = "Hit detection model deleted."
    }

    // MARK: - Export

    func exportRallyOnly() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        let keptSegments = effectiveKeptSegments
        guard !keptSegments.isEmpty else {
            lastErrorMessage = "No rally segments found. Run analysis first."
            return
        }

        isExporting = true
        statusMessage = "Exporting rally-only video..."
        lastErrorMessage = nil

        Task {
            do {
                let output = try await exporter.exportRallyOnly(assetURL: url, segments: keptSegments)
                statusMessage = "Exported: \(output.lastPathComponent)"
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
