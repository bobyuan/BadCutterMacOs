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

    // MARK: - Hit Model State
    @Published var hitModelStatus: HitModelStatus = .notTrained

    var hitModelURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        let modelURL = modelDir.appendingPathComponent("hit_classifier.mlmodelc")
        return FileManager.default.fileExists(atPath: modelURL.path) ? modelURL : nil
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
        analysisProgress = AnalysisProgress()
        statusMessage = "Loaded \(url.lastPathComponent)"
        lastErrorMessage = nil

        Task { await probeMetadata(url: url) }
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
                let frames = try await extractor.extractFeatures(from: url, mlModelURL: hitModelURL, progress: callbacks)
                self.featureFrames = frames

                analysisProgress.stage = .finalizing
                let classifier = HybridSegmenter()
                let rawSegments = classifier.classify(frames: frames, config: config)
                let processed = classifier.postProcess(segments: rawSegments, frames: frames, config: config)
                self.segments = processed

                deriveGameStructure()
                deriveTrimSegments()

                let rallyCount = processed.filter { $0.label == .rally }.count
                let elapsed = Date().timeIntervalSince(analysisStartTime ?? Date())
                analysisProgress = AnalysisProgress(
                    stage: .complete,
                    audioProgress: 1.0,
                    videoProgress: 1.0,
                    ralliesFound: rallyCount,
                    estimatedTrimPercent: removalStatistics?.trimPercent ?? 0,
                    elapsedSeconds: elapsed
                )
                let gameCount = games.count
                statusMessage = "Analysis complete: \(rallyCount) points in \(gameCount) game\(gameCount == 1 ? "" : "s") (\(formatElapsed(elapsed)))"
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
        games = GameDetector.detectGames(from: segments)
    }

    func setPointReviewStatus(pointID: UUID, status: PointReviewStatus) {
        for gameIdx in games.indices {
            if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                games[gameIdx].points[pointIdx].reviewStatus = status
                deriveTrimSegments()
                return
            }
        }
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

    // MARK: - Export

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
