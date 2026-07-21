import Foundation
import AVFoundation
import SwiftUI
import CoreML

@MainActor
final class AppState: ObservableObject {
    // MARK: - Video State
    @Published var videoItems: [VideoItem] = []
    @Published var currentAssetURL: URL?
    @Published var player: AVPlayer?
    @Published var videoMetadata: VideoMetadata?

    // MARK: - Multi-Video State
    @Published var videoResults: [URL: VideoAnalysisResult] = [:]
    @Published var batchQueue: [URL] = []
    @Published var batchIndex: Int = 0

    // MARK: - Analysis State
    @Published var segments: [TimeSegment] = []
    @Published var trimSegments: [TrimSegment] = []
    @Published var games: [Game] = []
    @Published var featureFrames: [FeatureFrame] = []
    @Published var racketHits: [RacketHitEvent] = []
    @Published var analysisProgress = AnalysisProgress()
    @Published var sensitivity: SensitivityPreset = .aggressive
    @Published var isAnalyzing = false

    // MARK: - Audio Signals (Phase 8: vDSP onsets + cheer timeline)
    @Published var audioSignals = AudioSignals()

    // MARK: - Serve & Score State
    @Published var serveSides: [UUID: ServeDetector.ServeSide] = [:]
    /// Which frame axis separates the parties (drives Near/Far vs Left/Right labels).
    @Published var serveAxis: ServeDetector.Axis = .horizontal
    @Published var pointScores: [UUID: ServeDetector.PointScore] = [:]

    // MARK: - Highlight State
    @Published var highlightScores: [UUID: Double] = [:]
    @Published var highlightTopK: Int = 10

    /// The top-K active points by highlight score.
    var topHighlightIDs: Set<UUID> {
        let ranked = games.flatMap(\.points)
            .filter { $0.reviewStatus != .deleted }
            .sorted { (highlightScores[$0.id] ?? 0) > (highlightScores[$1.id] ?? 0) }
        return Set(ranked.prefix(highlightTopK).map(\.id))
    }

    // MARK: - Calibration State
    @Published var calibrationFrames: [CalibrationFrame] = []
    @Published var selectedCalibrationFrameID: UUID?
    @Published var calibrationImages: [UUID: CGImage] = [:]

    // MARK: - Hit Model State
    @Published var hitModelStatus: HitModelStatus = .notTrained
    @Published var useHitModel: Bool = true
    @Published var hitModelVersions: [ModelVersionMetadata] = []
    let hitModelRegistry = ModelRegistry(modelName: "hit_classifier")

    // MARK: - Highlight Ranker State
    @Published var rankerVersions: [ModelVersionMetadata] = []
    @Published var rankerRatingCount = 0
    @Published var isTrainingRanker = false
    let rankerRegistry = ModelRegistry(modelName: HighlightRanker.modelName)
    private var rankerModel: MLModel?
    private var rankerModelVersion: Int?

    // MARK: - Training Pool State
    @Published var trainingPoolStatus: TrainingPoolStatus = .empty
    @Published var trainingPoolManifest: TrainingDataManifest = TrainingDataManifest()

    var hitModelExists: Bool {
        hitModelRegistry.currentModelURL() != nil
    }

    var hitModelURL: URL? {
        guard useHitModel else { return nil }
        return hitModelRegistry.currentModelURL()
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
    @Published var exportPlan = ExportPlan()
    @Published var exportOutputs: [ExportOutput] = []
    @Published var isExporting = false

    // MARK: - UI State
    @Published var statusMessage: String?
    @Published var lastErrorMessage: String?
    @Published var isShowingFileImporter = false

    // MARK: - Session (Corrections Ledger) State
    /// Analysis run currently loaded for this video (1-based).
    @Published var currentAnalysisRun: Int = 1
    @Published var runSummaries: [SessionStore.RunSummary] = []
    @Published var canUndo = false
    @Published var canRedo = false
    /// Points inserted by the user (effective `pointAdded` corrections).
    @Published var addedPointIDs: Set<UUID> = []
    /// Points whose boundaries were adjusted (effective `boundaryChanged` corrections).
    @Published var editedPointIDs: Set<UUID> = []
    /// Latest 👍/👎 per point, derived from `highlightRated` events.
    @Published var pointRatings: [UUID: HighlightRating] = [:]
    /// Manual serve-side corrections, derived from the ledger; they win over
    /// automatic detection permanently.
    @Published var serveOverrides: [UUID: ServeDetector.ServeSide] = [:]
    /// Manual winner for the match's final play (side of the winner).
    @Published var winnerOverrides: [UUID: ServeDetector.ServeSide] = [:]
    private var sessionBaseline: SessionBaseline?
    private var sessionEvents: [SessionEvent] = []
    private let sessionStore = SessionStore.shared

    private let exporter = VideoExporter()

    init() {
        // Adopt a pre-registry model file as v001, then reflect registry state.
        hitModelRegistry.migrateLegacyModel(at: hitModelOutputURL)
        refreshHitModelVersions()
        if let current = hitModelRegistry.currentVersion(),
           let meta = hitModelRegistry.metadata(forVersion: current) {
            hitModelStatus = .trained(accuracy: meta.trainingAccuracy, clipCount: meta.clipCount)
        }
        refreshTrainingPool()
        rankerVersions = rankerRegistry.versions()
        refreshRankerRatingCount()
    }

    func refreshHitModelVersions() {
        hitModelVersions = hitModelRegistry.versions()
    }

    // MARK: - Highlight Ranker

    func refreshRankerState() {
        rankerVersions = rankerRegistry.versions()
        // Invalidate the cached model when the pointer moved.
        if rankerModelVersion != rankerRegistry.currentVersion() {
            rankerModel = nil
            rankerModelVersion = nil
        }
        refreshHighlightScores()
    }

    /// Recount ratings across all sessions (cheap file scan, off-main).
    /// `thenAutoTrain` runs the debounced auto-training check afterwards —
    /// pass it only from natural pauses (DESIGN §8.3).
    func refreshRankerRatingCount(thenAutoTrain: Bool = false) {
        let store = sessionStore
        Task {
            let count = await Task.detached {
                HighlightRanker.collectSamples(store: store).count
            }.value
            rankerRatingCount = count
            if thenAutoTrain {
                maybeAutoTrainRanker()
            }
        }
    }

    private static let lastAutoTrainedCountKey = "rankerLastTrainedRatingCount"

    /// Debounced background training (DESIGN §8.3): first at 30 ratings, then
    /// every +10 beyond the last trained count. Called only at natural pauses
    /// (video switch, Models panel) so scores never reshuffle mid-review.
    func maybeAutoTrainRanker() {
        guard !isTrainingRanker else { return }
        let count = rankerRatingCount
        guard count >= HighlightRanker.minimumRatings else { return }
        let lastTrained = UserDefaults.standard.integer(forKey: Self.lastAutoTrainedCountKey)
        let isFirst = rankerVersions.isEmpty
        guard isFirst || count >= lastTrained + 10 else { return }
        trainHighlightRanker(automatic: true)
    }

    func trainHighlightRanker(automatic: Bool = false) {
        isTrainingRanker = true
        if !automatic {
            statusMessage = "Training highlight ranker…"
        }
        let store = sessionStore

        Task {
            do {
                let samples = await Task.detached {
                    HighlightRanker.collectSamples(store: store)
                }.value
                rankerRatingCount = samples.count

                let candidateURL = hitModelOutputURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("candidate_highlight_ranker.mlmodelc")
                let concordance = try await HighlightRanker.train(samples: samples, outputModelURL: candidateURL)

                var meta = try rankerRegistry.addVersion(
                    compiledModelAt: candidateURL,
                    clipCount: samples.count,
                    trainingAccuracy: concordance,
                    notes: "\(samples.count) ratings"
                )

                // Same gate shape as the hit model: concordance must not regress.
                let currentMeta = rankerRegistry.currentVersion()
                    .flatMap { rankerRegistry.metadata(forVersion: $0) }
                let decision: ShadowEval.GateDecision
                if let current = currentMeta, current.trainingAccuracy > 0,
                   concordance < current.trainingAccuracy - 0.02 {
                    decision = ShadowEval.GateDecision(
                        promote: false,
                        reason: String(format: "Concordance regressed: %.2f vs current %.2f.", concordance, current.trainingAccuracy)
                    )
                } else {
                    decision = ShadowEval.GateDecision(
                        promote: true,
                        reason: String(format: "Concordance %.2f over %d ratings.", concordance, samples.count)
                    )
                }
                meta.gateDecision = decision
                try? rankerRegistry.save(meta)

                let firstActivation = decision.promote && rankerRegistry.currentVersion() == nil
                if decision.promote {
                    rankerRegistry.promote(version: meta.version)
                    // Announce the moment scores change meaning (DESIGN §8.3).
                    statusMessage = firstActivation
                        ? "Scores now ranked by your taste — \(samples.count) ratings (\(meta.versionLabel)). Revert anytime in Models."
                        : "Ranker \(meta.versionLabel) trained and promoted — \(decision.reason)"
                } else if !automatic {
                    statusMessage = "Ranker \(meta.versionLabel) trained but NOT promoted — \(decision.reason)"
                }
                UserDefaults.standard.set(samples.count, forKey: Self.lastAutoTrainedCountKey)
                refreshRankerState()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            isTrainingRanker = false
        }
    }

    func promoteRanker(version: Int) {
        rankerRegistry.promote(version: version)
        refreshRankerState()
        statusMessage = String(format: "Now ranking highlights with v%03d.", version)
    }

    func deleteRanker() {
        rankerRegistry.removeAll()
        refreshRankerState()
        statusMessage = "Highlight ranker deleted — back to the built-in heuristic."
    }

    /// The promoted ranker model, loaded lazily and cached per version.
    private func loadedRankerModel() -> MLModel? {
        guard let version = rankerRegistry.currentVersion() else { return nil }
        if rankerModelVersion == version, let rankerModel { return rankerModel }
        rankerModel = HighlightRanker.loadModel(at: rankerRegistry.modelURL(forVersion: version))
        rankerModelVersion = rankerModel != nil ? version : nil
        return rankerModel
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

        // Skip duplicate — just select the existing video
        if videoItems.contains(where: { $0.url == url }) {
            selectVideo(url: url)
            return
        }

        let item = VideoItem(displayName: url.lastPathComponent, url: url)
        videoItems.append(item)
        selectVideo(url: url)
        statusMessage = "Loaded \(url.lastPathComponent)"
    }

    // MARK: - Multi-Video Management

    func selectVideo(url: URL) {
        // Save current video state before switching
        saveCurrentVideoState()

        currentAssetURL = url
        player = AVPlayer(url: url)
        lastErrorMessage = nil

        // Restore target video's state
        restoreVideoState(for: url)

        // Probe metadata if not yet available
        if videoMetadata == nil {
            Task { await probeMetadata(url: url) }
        }
        loadCalibrationData()

        // Natural pause: debounced ranker training (§8.3) — after the switch
        // finishes, so the background scan never races the session load.
        refreshRankerRatingCount(thenAutoTrain: true)
    }

    func saveCurrentVideoState() {
        guard let url = currentAssetURL else { return }
        let status: VideoAnalysisStatus
        if isAnalyzing {
            status = .analyzing
        } else if !segments.isEmpty {
            status = .done
        } else if let existing = videoResults[url]?.status, case .error = existing {
            status = existing
        } else {
            status = .notAnalyzed
        }

        videoResults[url] = VideoAnalysisResult(
            status: status,
            segments: segments,
            trimSegments: trimSegments,
            games: games,
            featureFrames: featureFrames,
            racketHits: racketHits,
            serveSides: serveSides,
            pointScores: pointScores,
            analysisProgress: analysisProgress,
            videoMetadata: videoMetadata,
            calibrationFrames: calibrationFrames,
            calibrationImages: calibrationImages,
            sessionBaseline: sessionBaseline,
            sessionEvents: sessionEvents,
            audioSignals: audioSignals
        )
    }

    private func restoreVideoState(for url: URL) {
        if let result = videoResults[url] {
            segments = result.segments
            trimSegments = result.trimSegments
            games = result.games
            featureFrames = result.featureFrames
            racketHits = result.racketHits
            serveSides = result.serveSides
            pointScores = result.pointScores
            analysisProgress = result.analysisProgress
            videoMetadata = result.videoMetadata
            calibrationFrames = result.calibrationFrames
            selectedCalibrationFrameID = result.calibrationFrames.first?.id
            calibrationImages = result.calibrationImages
            sessionBaseline = result.sessionBaseline
            sessionEvents = result.sessionEvents
            audioSignals = result.audioSignals
            if let vid = sessionStore.videoID(for: url) {
                currentAnalysisRun = sessionStore.currentRun(forVideoID: vid) ?? 1
            }
            refreshRunSummaries(for: url)
            refreshSessionDerivedState()
            refreshHighlightScores()
        } else {
            segments = []
            trimSegments = []
            games = []
            featureFrames = []
            racketHits = []
            serveSides = [:]
            pointScores = [:]
            analysisProgress = AnalysisProgress()
            videoMetadata = nil
            calibrationFrames = []
            selectedCalibrationFrameID = nil
            calibrationImages = [:]
            calibrationSessionID = ""
            sessionBaseline = nil
            sessionEvents = []
            audioSignals = AudioSignals()
            currentAnalysisRun = 1
            runSummaries = []
            refreshSessionDerivedState()

            // No in-memory state — try restoring a persisted session from disk.
            restoreSessionFromDisk(for: url)
        }
    }

    /// Restore a previously analyzed video's state from its persisted session
    /// (baseline + correction-event replay + cached feature frames).
    private func restoreSessionFromDisk(for url: URL) {
        guard let loaded = sessionStore.loadSession(for: url),
              !loaded.baseline.games.isEmpty else { return }

        applyLoadedSession(loaded)
        refreshRunSummaries(for: url)

        let pointCount = games.reduce(0) { $0 + $1.activePointCount }
        analysisProgress = AnalysisProgress(
            stage: .complete,
            audioProgress: 1.0,
            videoProgress: 1.0,
            ralliesFound: pointCount
        )
        statusMessage = "Restored previous session: \(pointCount) points"

        // Mirror into the in-memory cache so status dots show "done"
        saveCurrentVideoStateSnapshot(for: url)
    }

    private func saveCurrentVideoStateSnapshot(for url: URL) {
        videoResults[url] = VideoAnalysisResult(
            status: .done,
            segments: segments,
            trimSegments: trimSegments,
            games: games,
            featureFrames: featureFrames,
            racketHits: racketHits,
            serveSides: serveSides,
            pointScores: pointScores,
            analysisProgress: analysisProgress,
            videoMetadata: videoMetadata,
            calibrationFrames: calibrationFrames,
            calibrationImages: calibrationImages,
            sessionBaseline: sessionBaseline,
            sessionEvents: sessionEvents,
            audioSignals: audioSignals
        )
    }

    func removeVideo(id: UUID) {
        guard let idx = videoItems.firstIndex(where: { $0.id == id }) else { return }
        let removed = videoItems.remove(at: idx)
        videoResults.removeValue(forKey: removed.url)

        if removed.url == currentAssetURL {
            if let next = videoItems.first {
                selectVideo(url: next.url)
            } else {
                currentAssetURL = nil
                player = nil
                segments = []
                trimSegments = []
                games = []
                featureFrames = []
                racketHits = []
                serveSides = [:]
                pointScores = [:]
                analysisProgress = AnalysisProgress()
                videoMetadata = nil
                calibrationFrames = []
                selectedCalibrationFrameID = nil
                calibrationImages = [:]
                calibrationSessionID = ""
            }
        }
    }

    func moveVideo(from source: IndexSet, to destination: Int) {
        videoItems.move(fromOffsets: source, toOffset: destination)
    }

    func selectAllVideos() {
        for i in videoItems.indices {
            videoItems[i].isSelected = true
        }
    }

    func selectNoVideos() {
        for i in videoItems.indices {
            videoItems[i].isSelected = false
        }
    }

    func analysisStatus(for url: URL) -> VideoAnalysisStatus {
        videoResults[url]?.status ?? .notAnalyzed
    }

    // MARK: - Batch Analysis

    func analyzeBatch() {
        let selected = videoItems.filter(\.isSelected).map(\.url)
        guard !selected.isEmpty else { return }
        batchQueue = selected
        batchIndex = 0
        analyzeNextInBatch()
    }

    private func analyzeNextInBatch() {
        guard batchIndex < batchQueue.count else {
            let total = batchQueue.count
            batchQueue = []
            batchIndex = 0
            statusMessage = "Batch complete: analyzed \(total) video\(total == 1 ? "" : "s")"
            return
        }

        let url = batchQueue[batchIndex]
        // Skip already-analyzed videos
        if case .done = analysisStatus(for: url) {
            batchIndex += 1
            analyzeNextInBatch()
            return
        }

        selectVideo(url: url)
        analyzeCurrentVideo {
            self.batchIndex += 1
            self.analyzeNextInBatch()
        }
    }

    var isBatchAnalyzing: Bool {
        !batchQueue.isEmpty
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

    func analyzeCurrentVideo(onComplete: (() -> Void)? = nil) {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        let analyzingURL = url
        isAnalyzing = true
        statusMessage = isBatchAnalyzing
            ? "Analyzing \(batchIndex + 1) of \(batchQueue.count)..."
            : "Analyzing..."
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

                statusMessage = "Analyzing audio (onsets + crowd)..."
                self.audioSignals = await AudioSignalExtractor.extract(from: url)

                analysisProgress.stage = .finalizing
                let classifier = HybridSegmenter()
                let rawSegments = classifier.classify(frames: frames, config: config)
                let processed = classifier.postProcess(segments: rawSegments, frames: frames, config: config)
                let taRefined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
                // Clean up TA artifacts: remove 0-duration segments, merge consecutive same-label
                let refined = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(taRefined), maxGap: 0.5)
                self.segments = refined

                deriveGameStructure()
                deriveTrimSegments()
                refreshHighlightScores()
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
                // Persist the analysis as a new run (older runs are kept)
                persistBaseline(for: analyzingURL)
                let gameCount = games.count
                let historyNote = currentAnalysisRun > 1
                    ? " Analysis #\(currentAnalysisRun); earlier versions kept in History — switch back anytime."
                    : ""
                statusMessage = "Analysis complete\(mlStatus): \(rallyCount) points in \(gameCount) game\(gameCount == 1 ? "" : "s") (\(formatElapsed(elapsed))).\(historyNote)"
                sessionStore.saveAudioSignals(audioSignals, for: analyzingURL)
                // Save results for this video
                saveCurrentVideoState()
                // If user navigated away during analysis, update the result for the analyzed URL
                if currentAssetURL != analyzingURL {
                    videoResults[analyzingURL]?.status = .done
                }
            } catch {
                lastErrorMessage = error.localizedDescription
                // Save error status
                if var result = videoResults[analyzingURL] {
                    result.status = .error(error.localizedDescription)
                    videoResults[analyzingURL] = result
                } else {
                    videoResults[analyzingURL] = VideoAnalysisResult(
                        status: .error(error.localizedDescription)
                    )
                }
            }
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            isAnalyzing = false
            onComplete?()
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
                recordEvent(status == .deleted ? .pointDeleted(pointID: pointID) : .pointRestored(pointID: pointID))
                return
            }
        }
    }

    // MARK: - Session Ledger

    /// Append an event to the current video's ledger (in memory + on disk).
    private func recordEvent(_ event: SessionEvent) {
        guard let url = currentAssetURL else { return }
        sessionEvents.append(event)
        sessionStore.append(event, for: url, run: currentAnalysisRun)
        refreshSessionDerivedState()

        // §8.6: after a few corrections on a video that isn't in the training
        // pool yet, nudge once toward Save for Training.
        if event.isCorrection, currentRunAdjustmentCount == 3, !currentVideoInPool {
            statusMessage = "3 corrections on this video — Save for Training (Points panel) so the models learn from them."
        }
    }

    private func refreshSessionDerivedState() {
        let counts = SessionMaterializer.undoRedoCounts(from: sessionEvents)
        canUndo = counts.undoable > 0
        canRedo = counts.redoable > 0

        var added: Set<UUID> = []
        var edited: Set<UUID> = []
        for event in SessionMaterializer.effectiveCorrections(from: sessionEvents) {
            switch event {
            case .pointAdded(let pointID, _, _):
                added.insert(pointID)
            case .boundaryChanged(let pointID, _, _, _):
                edited.insert(pointID)
            default:
                break
            }
        }
        addedPointIDs = added
        editedPointIDs = edited

        // Ratings are audit events, not corrections: last one per point wins,
        // and undo/redo never touches them.
        var ratings: [UUID: HighlightRating] = [:]
        var overrides: [UUID: ServeDetector.ServeSide] = [:]
        var winners: [UUID: ServeDetector.ServeSide] = [:]
        for event in sessionEvents {
            if case .highlightRated(let pointID, let raw) = event {
                if let rating = HighlightRating(rawValue: raw) {
                    ratings[pointID] = rating
                } else {
                    ratings.removeValue(forKey: pointID)
                }
            }
            if case .serveSideOverridden(let pointID, let raw) = event,
               let side = ServeDetector.ServeSide(rawValue: raw) {
                overrides[pointID] = side
            }
            if case .pointWinnerOverridden(let pointID, let raw) = event,
               let side = ServeDetector.ServeSide(rawValue: raw) {
                winners[pointID] = side
            }
        }
        pointRatings = ratings
        serveOverrides = overrides
        winnerOverrides = winners
    }

    /// Derived review state for the point-list chip.
    func reviewChip(for point: GamePoint) -> ReviewChip {
        if point.reviewStatus == .deleted { return .deleted }
        if addedPointIDs.contains(point.id) { return .added }
        if editedPointIDs.contains(point.id) { return .edited }
        if point.reviewStatus == .confirmed || pointRatings[point.id] != nil { return .confirmed }
        return .auto
    }

    /// Whether add-point is possible (an analysis baseline exists to correct).
    var canAddPoint: Bool {
        sessionBaseline != nil
    }

    /// Insert a user-added point at the playhead (DESIGN §3.2). Span defaults
    /// to the surrounding break's high-audio window, else ±4s; boundaries stay
    /// draggable afterwards. Recorded as an undoable `pointAdded` correction,
    /// so it flows into scoring, export, and training-clip extraction like any
    /// other active point.
    @discardableResult
    func addPoint(at time: TimeInterval) -> UUID? {
        guard sessionBaseline != nil else {
            lastErrorMessage = "Analyze the video before adding points."
            return nil
        }
        let activeSegments = games.flatMap(\.points)
            .filter { $0.reviewStatus != .deleted }
            .map(\.rallySegment)
        let duration = videoMetadata?.duration
            ?? sessionBaseline?.videoDuration
            ?? max(featureFrames.last?.timestamp ?? 0, time + 4)
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: time,
            frames: featureFrames,
            activeSegments: activeSegments,
            videoDuration: duration
        )
        let pointID = UUID()
        recordEvent(.pointAdded(pointID: pointID, start: span.start, end: span.end))
        rematerializeFromSession()
        statusMessage = String(format: "Added point %.1fs – %.1fs — drag the handles to adjust", span.start, span.end)
        return pointID
    }

    /// Toggle a 👍/👎 highlight rating; tapping the active rating clears it
    /// (recorded as rating "none").
    func ratePoint(pointID: UUID, rating: HighlightRating) {
        let raw = pointRatings[pointID] == rating ? "none" : rating.rawValue
        recordEvent(.highlightRated(pointID: pointID, rating: raw))
    }

    // MARK: - Feedback-Driven Adjustment

    struct FeedbackOutcome {
        /// Point the tune UI should focus (nil when the point was deleted).
        var focusPointID: UUID?
        /// Pre-adjustment boundaries, for ghost display.
        var ghostStart: TimeInterval?
        var ghostEnd: TimeInterval?
        var autoAdjusted: Bool
    }

    /// Handle a 👎 reason: record it, apply the automatic fix through the
    /// ordinary ledger paths (always undoable), and tell the caller where to
    /// focus the tune UI. `notHighlight` never reaches here — the menu records
    /// a plain rating for it, keeping the ranker's taste pool clean (D-008).
    @discardableResult
    func applyFeedback(pointID: UUID, reason: PointFeedbackReason) -> FeedbackOutcome? {
        guard let point = point(withID: pointID) else { return nil }
        recordEvent(.pointFeedback(pointID: pointID, reason: reason.rawValue))

        if reason == .notHighlight {
            if pointRatings[pointID] != .down {
                recordEvent(.highlightRated(pointID: pointID, rating: HighlightRating.down.rawValue))
            }
            return FeedbackOutcome(focusPointID: nil, ghostStart: nil, ghostEnd: nil, autoAdjusted: false)
        }
        if reason == .notAPoint {
            setPointReviewStatus(pointID: pointID, status: .deleted)
            statusMessage = "Point #\(point.pointNumber) deleted — labeled false positive (great training signal)."
            return FeedbackOutcome(focusPointID: nil, ghostStart: nil, ghostEnd: nil, autoAdjusted: true)
        }

        // Flush against a neighbor, "cut off" complaint → the neighbor IS the
        // continuation of this rally: absorb it (delete neighbor, take its span).
        if reason == .endsTooEarly,
           let next = activePoints.first(where: { $0.start >= point.end - 0.01 && $0.id != pointID }),
           next.start - point.end < 0.35 {
            return mergeAbsorbing(neighbor: next, into: point, edge: .end)
        }
        if reason == .startsTooLate,
           let previous = activePoints.last(where: { $0.end <= point.start + 0.01 && $0.id != pointID }),
           point.start - previous.end < 0.35 {
            return mergeAbsorbing(neighbor: previous, into: point, edge: .start)
        }

        // Signal-based fix first; when the evidence is inconclusive (or the
        // reason is repeated after the signal is exhausted), honor the user's
        // explicit judgment with a fixed nudge they can refine by dragging.
        var usedFallback = false
        var resolved = PointAdjuster.propose(reason: reason, context: adjusterContext(for: point))
        if resolved == nil {
            resolved = fallbackProposal(reason: reason, point: point)
            usedFallback = resolved != nil
        }
        guard let proposal = resolved else {
            statusMessage = "Nothing left to adjust automatically — drag the orange handles to fine-tune."
            return FeedbackOutcome(focusPointID: pointID, ghostStart: nil, ghostEnd: nil, autoAdjusted: false)
        }
        let suffix = usedFallback
            ? " (no clear signal — fixed nudge; drag the orange handle to refine)"
            : ""

        switch proposal {
        case .adjustStart(let to):
            let from = point.start
            updatePointBoundary(pointID: pointID, newStart: to)
            commitPointBoundary(pointID: pointID, edge: .start, from: from, to: to)
            deriveTrimSegments()
            computeAllScores()
            var message = String(format: "Start moved %+.1fs (%@).%@", to - from, reason.label, suffix)
            if reason == .startsTooLate {
                let pieces = resegmentPoint(pointID: pointID)
                if pieces > 1 { message += " Extended span contained \(pieces) rallies — split them." }
            }
            statusMessage = message + " ⌘Z to undo."
            return FeedbackOutcome(focusPointID: pointID, ghostStart: from, ghostEnd: nil, autoAdjusted: true)

        case .adjustEnd(let to):
            let from = point.end
            updatePointBoundary(pointID: pointID, newEnd: to)
            commitPointBoundary(pointID: pointID, edge: .end, from: from, to: to)
            deriveTrimSegments()
            computeAllScores()
            var message = String(format: "End moved %+.1fs (%@).%@", to - from, reason.label, suffix)
            if reason == .endsTooEarly {
                let pieces = resegmentPoint(pointID: pointID)
                if pieces > 1 { message += " Extended span contained \(pieces) rallies — split them." }
            }
            statusMessage = message + " ⌘Z to undo."
            return FeedbackOutcome(focusPointID: pointID, ghostStart: nil, ghostEnd: from, autoAdjusted: true)

        case .split(let firstEnd, let secondStart):
            let originalEnd = point.end
            updatePointBoundary(pointID: pointID, newEnd: firstEnd)
            commitPointBoundary(pointID: pointID, edge: .end, from: originalEnd, to: firstEnd)
            let newID = UUID()
            recordEvent(.pointAdded(pointID: newID, start: secondStart, end: originalEnd))
            rematerializeFromSession()
            statusMessage = String(format: "Split at %@ into two points. ⌘Z twice to undo.", Self.formatTimestamp(firstEnd))
            return FeedbackOutcome(focusPointID: newID, ghostStart: nil, ghostEnd: originalEnd, autoAdjusted: true)

        case .insertBefore(let start, let end):
            let newID = UUID()
            recordEvent(.pointAdded(pointID: newID, start: start, end: end))
            rematerializeFromSession()
            statusMessage = String(format: "Added missed point %@ – %@ — drag or tune to adjust.",
                                   Self.formatTimestamp(start), Self.formatTimestamp(end))
            return FeedbackOutcome(focusPointID: newID, ghostStart: nil, ghostEnd: nil, autoAdjusted: true)
        }
    }

    /// Absorb a flush neighbor into the complained-about point: delete the
    /// neighbor and take over its span (two ledger events; ⌘Z twice undoes).
    private func mergeAbsorbing(neighbor: GamePoint, into target: GamePoint, edge: BoundaryEdge) -> FeedbackOutcome {
        setPointReviewStatus(pointID: neighbor.id, status: .deleted)
        switch edge {
        case .end:
            updatePointBoundary(pointID: target.id, newEnd: neighbor.end)
            commitPointBoundary(pointID: target.id, edge: .end, from: target.end, to: neighbor.end)
        case .start:
            updatePointBoundary(pointID: target.id, newStart: neighbor.start)
            commitPointBoundary(pointID: target.id, edge: .start, from: target.start, to: neighbor.start)
        }
        deriveTrimSegments()
        computeAllScores()
        let pieces = resegmentPoint(pointID: target.id)
        var message = edge == .end
            ? "Merged with the next point — the rally continues through it."
            : "Merged with the previous point — the rally started there."
        if pieces > 1 { message += " The combined span contained \(pieces) rallies — split them." }
        statusMessage = message + " ⌘Z to walk back."
        return FeedbackOutcome(
            focusPointID: target.id,
            ghostStart: edge == .start ? target.start : nil,
            ghostEnd: edge == .end ? target.end : nil,
            autoAdjusted: true
        )
    }

    /// Re-run local detection over a point's (possibly extended) span and
    /// split it at internal breaks — an extension can contain two rallies.
    /// Returns how many points the span became (1 = unchanged). All splits go
    /// through the ledger (boundaryChanged + pointAdded), so undo walks back.
    @discardableResult
    func resegmentPoint(pointID: UUID) -> Int {
        guard let target = point(withID: pointID) else { return 1 }
        let ctx = adjusterContext(for: target)
        let breaks = PointAdjuster.internalBreaks(from: target.start, to: target.end, context: ctx)
        guard !breaks.isEmpty else { return 1 }

        var spans: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor = target.start
        for gap in breaks {
            let segmentEnd = gap.start + 0.3
            if segmentEnd - cursor >= 1.0 { spans.append((cursor, segmentEnd)) }
            cursor = gap.end - 0.3
        }
        if target.end - cursor >= 1.0 { spans.append((cursor, target.end)) }
        guard spans.count >= 2 else { return 1 }

        let originalEnd = target.end
        updatePointBoundary(pointID: pointID, newEnd: spans[0].end)
        commitPointBoundary(pointID: pointID, edge: .end, from: originalEnd, to: spans[0].end)
        for span in spans.dropFirst() {
            recordEvent(.pointAdded(pointID: UUID(), start: span.start, end: span.end))
        }
        rematerializeFromSession()
        return spans.count
    }

    /// Split the active play containing `time` into two points exactly there
    /// (playhead right-click). Ledger: boundaryChanged + pointAdded; ⌘Z twice
    /// walks it back.
    func splitPlay(at time: TimeInterval) {
        guard let target = activePoints.first(where: { time > $0.start && time < $0.end }) else {
            statusMessage = "Place the playhead inside a play to split it."
            return
        }
        guard time - target.start >= 0.5, target.end - time >= 0.5 else {
            statusMessage = "Too close to the boundary — move the playhead at least 0.5s into the play."
            return
        }
        let originalEnd = target.end
        updatePointBoundary(pointID: target.id, newEnd: time)
        commitPointBoundary(pointID: target.id, edge: .end, from: originalEnd, to: time)
        recordEvent(.pointAdded(pointID: UUID(), start: time, end: originalEnd))
        rematerializeFromSession()
        statusMessage = String(format: "Split at %d:%02d into two plays. ⌘Z twice to undo.", Int(time) / 60, Int(time) % 60)
    }

    /// Right-click: refresh scores from a play onward WITHOUT re-analysis —
    /// clears detected serve sides from there (pinned overrides survive),
    /// re-detects them (a few frame reads), and recomputes the score chain.
    func recalculateScores(fromPointID pointID: UUID) {
        guard let target = point(withID: pointID) else { return }
        // "From here" means earlier rows must not move: freeze the displayed
        // chain above this play so the re-detection pass (which also fills
        // any still-missing earlier serves) cannot rewrite it.
        pinDisplayedWinners(before: pointID)
        // Strictly AFTER the selected play: its own serve encodes the FORMER
        // play's winner and must not be disturbed by a forward recalculation.
        let affected = activePoints.filter { $0.start > target.start + 0.01 }
        for p in affected where serveOverrides[p.id] == nil {
            serveSides.removeValue(forKey: p.id)
            serveDirtyIDs.insert(p.id)
        }
        computeAllScores()
        scheduleServeRedetection()
        statusMessage = "Re-detecting serve parties for \(affected.count) plays from #\(target.pointNumber) (vision model) — scores refresh in a moment."
    }

    /// After a MANUAL extension, don't auto-split — surface the finding.
    func suggestSplitIfNeeded(pointID: UUID) {
        guard let target = point(withID: pointID) else { return }
        let ctx = adjusterContext(for: target)
        let count = PointAdjuster.internalBreaks(from: target.start, to: target.end, context: ctx).count
        if count > 0 {
            statusMessage = "This play looks like it contains \(count + 1) rallies — right-click it and choose the split option."
        }
    }

    /// Hard limits for dragging/extending a point's boundaries: the previous
    /// active point's end and the next active point's start.
    func boundaryLimits(for pointID: UUID) -> (minStart: TimeInterval, maxEnd: TimeInterval) {
        guard let target = point(withID: pointID) else { return (0, .greatestFiniteMagnitude) }
        let active = activePoints
        let prevEnd = active.last(where: { $0.end <= target.start + 0.01 && $0.id != pointID })?.end ?? 0
        let duration = videoMetadata?.duration
            ?? sessionBaseline?.videoDuration
            ?? (featureFrames.last?.timestamp ?? target.end + 60)
        let nextStart = active.first(where: { $0.start >= target.end - 0.01 && $0.id != pointID })?.start ?? duration
        return (prevEnd, nextStart)
    }

    /// Public wrapper so drag handles can refresh trims + scores on release.
    func refreshDerivedAfterBoundaryChange() {
        resortAndRenumberPoints()
        deriveTrimSegments()
        computeAllScores()
    }

    /// Fixed nudge used when the signal-based adjuster declines: extend 1s
    /// for "cut off" reasons, trim 0.5s for "dead time" reasons, clamped.
    private func fallbackProposal(reason: PointFeedbackReason, point: GamePoint) -> PointAdjuster.Proposal? {
        let limits = boundaryLimits(for: point.id)
        switch reason {
        case .endsTooEarly:
            let to = min(limits.maxEnd - 0.05, point.end + 1.0)
            return to - point.end >= 0.2 ? .adjustEnd(to: to) : nil
        case .startsTooLate:
            let to = max(limits.minStart + 0.05, point.start - 1.0)
            return point.start - to >= 0.2 ? .adjustStart(to: to) : nil
        case .startsTooEarly:
            let to = min(point.end - 1.0, point.start + 0.5)
            return to - point.start >= 0.2 ? .adjustStart(to: to) : nil
        case .endsTooLate:
            let to = max(point.start + 1.0, point.end - 0.5)
            return point.end - to >= 0.2 ? .adjustEnd(to: to) : nil
        default:
            return nil
        }
    }

    /// Feedback-reason tallies for the loaded video, across all runs
    /// (DESIGN §8.6) — recurring complaints are config-tuning signal.
    func feedbackReasonCounts() -> [(reason: PointFeedbackReason, count: Int)] {
        guard let url = currentAssetURL, let vid = sessionStore.videoID(for: url) else { return [] }
        var counts: [PointFeedbackReason: Int] = [:]
        for entry in sessionStore.loadLedger(forVideoID: vid) {
            if case .pointFeedback(_, let raw) = entry.event,
               let reason = PointFeedbackReason(rawValue: raw), reason != .notHighlight {
                counts[reason, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func adjusterContext(for point: GamePoint) -> PointAdjuster.Context {
        let active = activePoints
        let previousEnd = active.last(where: { $0.end <= point.start + 0.01 && $0.id != point.id })?.end ?? 0
        let duration = videoMetadata?.duration
            ?? sessionBaseline?.videoDuration
            ?? (featureFrames.last?.timestamp ?? point.end + 5)
        let nextStart = active.first(where: { $0.start >= point.end - 0.01 && $0.id != point.id })?.start ?? duration
        return PointAdjuster.Context(
            point: point,
            previousEnd: previousEnd,
            nextStart: nextStart,
            frames: featureFrames,
            onsets: audioSignals.onsets,
            videoDuration: duration
        )
    }

    /// Nudge one boundary by a delta (tune-bar buttons). Ledger-recorded.
    func nudgeBoundary(pointID: UUID, edge: BoundaryEdge, delta: TimeInterval) {
        guard let target = point(withID: pointID) else { return }
        switch edge {
        case .start:
            let from = target.start
            updatePointBoundary(pointID: pointID, newStart: from + delta)
            if let moved = point(withID: pointID)?.start {
                commitPointBoundary(pointID: pointID, edge: .start, from: from, to: moved)
            }
        case .end:
            let from = target.end
            updatePointBoundary(pointID: pointID, newEnd: from + delta)
            if let moved = point(withID: pointID)?.end {
                commitPointBoundary(pointID: pointID, edge: .end, from: from, to: moved)
            }
        }
        deriveTrimSegments()
        computeAllScores()
    }

    /// Set one boundary to an absolute time (tune-bar "set = playhead").
    func setBoundary(pointID: UUID, edge: BoundaryEdge, to time: TimeInterval) {
        guard let target = point(withID: pointID) else { return }
        let from = edge == .start ? target.start : target.end
        nudgeBoundary(pointID: pointID, edge: edge, delta: time - from)
    }

    private static func formatTimestamp(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    /// Look up a point across all games.
    func point(withID id: UUID) -> GamePoint? {
        games.flatMap(\.points).first { $0.id == id }
    }

    /// Record a completed boundary drag as a ledger event. The live mutation
    /// already happened via updatePointBoundary during the drag; this logs the
    /// net change (drag start → drag end) for undo and training.
    func commitPointBoundary(pointID: UUID, edge: BoundaryEdge, from: TimeInterval, to: TimeInterval) {
        guard abs(from - to) > 0.01 else { return }
        recordEvent(.boundaryChanged(pointID: pointID, edge: edge, from: from, to: to))
        resortAndRenumberPoints()
        refreshHighlightScores()
        if edge == .start {
            serveDirtyIDs.insert(pointID)
            scheduleServeRedetection()
        }
    }

    func undo() {
        guard canUndo else { return }
        recordEvent(.undo)
        rematerializeFromSession()
    }

    func redo() {
        guard canRedo else { return }
        recordEvent(.redo)
        rematerializeFromSession()
    }

    /// Rebuild games from baseline + effective corrections (after undo/redo).
    private func rematerializeFromSession() {
        guard let baseline = sessionBaseline else { return }
        let effective = SessionMaterializer.effectiveCorrections(from: sessionEvents)
        games = SessionMaterializer.apply(events: effective, to: baseline.games)
        deriveTrimSegments()
        computeAllScores()
        scheduleServeRedetection()
    }

    /// Persist a fresh analysis result as the session baseline.
    private func persistBaseline(for url: URL) {
        let saved = sessionStore.saveBaseline(
            segments: segments,
            games: games,
            serveSides: serveSides,
            videoDuration: videoMetadata?.duration,
            frames: featureFrames,
            usedHitModel: hitModelURL != nil,
            for: url
        )
        sessionBaseline = saved?.baseline
        currentAnalysisRun = saved?.run ?? 1
        refreshRunSummaries(for: url)
        sessionEvents = []
        refreshSessionDerivedState()
    }

    private func refreshRunSummaries(for url: URL) {
        runSummaries = sessionStore.videoID(for: url)
            .map { sessionStore.runSummaries(forVideoID: $0) } ?? []
    }

    /// Number of adjustment events recorded on the current run (for the
    /// re-analyze confirmation).
    var currentRunAdjustmentCount: Int {
        sessionEvents.filter { $0.isCorrection }.count
    }

    /// Switch the loaded video to another analysis run. All state (points,
    /// corrections, scores, audio signals) reloads from that run; nothing is
    /// written except the current-run pointer.
    func switchToRun(_ run: Int) {
        guard let url = currentAssetURL,
              let vid = sessionStore.videoID(for: url),
              run != currentAnalysisRun,
              let loaded = sessionStore.loadRun(videoID: vid, run: run) else { return }
        sessionStore.setCurrentRun(run, forVideoID: vid)
        applyLoadedSession(loaded)
        let pointCount = games.reduce(0) { $0 + $1.activePointCount }
        statusMessage = "Switched to Analysis #\(run) — \(pointCount) points, with your adjustments restored."
    }

    /// Install a loaded session (any run) as the live state.
    private func applyLoadedSession(_ loaded: SessionStore.LoadedSession) {
        sessionBaseline = loaded.baseline
        sessionEvents = loaded.events
        currentAnalysisRun = loaded.run
        segments = loaded.baseline.segments
        featureFrames = loaded.frames
        audioSignals = loaded.audioSignals ?? AudioSignals()
        serveSides = loaded.baseline.serveSides
        serveAxis = loaded.baseline.serveAxis ?? .horizontal

        let effective = SessionMaterializer.effectiveCorrections(from: loaded.events)
        games = SessionMaterializer.apply(events: effective, to: loaded.baseline.games)

        deriveTrimSegments()
        computeAllScores()
        refreshSessionDerivedState()
        scheduleServeRedetection()
    }

    /// Point labels ("#N (m:ss)") for a run, resolved against that run's own
    /// materialized points — so history rows stay meaningful for older runs.
    func pointLabels(forRun run: Int) -> [UUID: String] {
        guard let url = currentAssetURL,
              let vid = sessionStore.videoID(for: url),
              let baseline = sessionStore.loadBaseline(forVideoID: vid, run: run) else { return [:] }
        let events = sessionStore.ledgerEntries(forVideoID: vid, run: run).map(\.event)
        let games = SessionMaterializer.apply(
            events: SessionMaterializer.effectiveCorrections(from: events),
            to: baseline.games
        )
        var labels: [UUID: String] = [:]
        for point in games.flatMap(\.points) {
            labels[point.id] = String(format: "#%d (%d:%02d)", point.pointNumber, Int(point.start) / 60, Int(point.start) % 60)
        }
        return labels
    }

    /// Ledger entries for one run, newest first (History tab).
    func historyEntries(forRun run: Int) -> [LedgerEntry] {
        guard let url = currentAssetURL, let vid = sessionStore.videoID(for: url) else { return [] }
        return sessionStore.ledgerEntries(forVideoID: vid, run: run).reversed()
    }

    /// Reveal the on-disk session folder (History tab footer).
    func revealSessionFolder() {
        guard let url = currentAssetURL, let dir = sessionStore.sessionDirectory(for: url) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: - Serve Detection & Scoring

    /// Physical hint for a side under the detected camera orientation:
    /// horizontal split → Left/Right; vertical split → Far (top) / Near (bottom).
    func serveSideLabel(_ side: ServeDetector.ServeSide) -> String {
        switch (side, serveAxis) {
        case (.left, .horizontal): return "Left"
        case (.right, .horizontal): return "Right"
        case (.left, .vertical): return "Far"
        case (.right, .vertical): return "Near"
        case (.unknown, _): return "Unknown"
        }
    }

    /// The side that anchors "A" for a game — strictly the FIRST active
    /// point's effective side; only if that is unknown, the earliest known
    /// side. Single source of truth for score columns and A/B labels.
    func anchorSide(for game: Game) -> ServeDetector.ServeSide? {
        let active = game.points.filter { $0.reviewStatus != .deleted }
        if let first = active.first,
           let side = effectiveServeSide(for: first.id), side != .unknown {
            return side
        }
        for point in active {
            if let side = effectiveServeSide(for: point.id), side != .unknown {
                return side
            }
        }
        return nil
    }

    /// A/B labels aligned with the score columns: "Side A" is the party that
    /// served the game's first point (the score reads A:B).
    func serveMenuLabels(for game: Game) -> (left: String, right: String) {
        let firstSide = anchorSide(for: game) ?? .left
        let aIsLeft = firstSide != .right
        return (aIsLeft ? "Side A" : "Side B", aIsLeft ? "Side B" : "Side A")
    }

    /// The score entering a play: the previous active play's score, 0:0 for
    /// the game's first active play. nil when no score is computed yet.
    func scoreBefore(of pointID: UUID) -> ServeDetector.PointScore? {
        guard pointScores[pointID] != nil,
              let game = games.first(where: { $0.points.contains(where: { $0.id == pointID }) }) else { return nil }
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard let idx = active.firstIndex(where: { $0.id == pointID }) else { return nil }
        return idx > 0 ? pointScores[active[idx - 1].id] : ServeDetector.PointScore(scoreA: 0, scoreB: 0)
    }

    /// Who won a play under the current scores (true = Side A), derived by
    /// comparing its score row with the previous play's.
    func winnerIsA(of pointID: UUID) -> Bool? {
        guard let game = games.first(where: { $0.points.contains(where: { $0.id == pointID }) }),
              let score = pointScores[pointID] else { return nil }
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard let idx = active.firstIndex(where: { $0.id == pointID }) else { return nil }
        let previous = idx > 0 ? pointScores[active[idx - 1].id] : ServeDetector.PointScore(scoreA: 0, scoreB: 0)
        guard let prev = previous else { return nil }
        if score.scoreA > prev.scoreA { return true }
        if score.scoreB > prev.scoreB { return false }
        return nil
    }

    /// Freeze the A/B anchor before any manual score correction: if the
    /// game's first play has no known side, pin it to the current anchor so a
    /// later correction can never re-anchor A/B and flip earlier plays.
    private func freezeAnchorIfNeeded(for game: Game) {
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard let first = active.first else { return }
        // Pin even a DETECTED first side: detected values can be re-detected
        // later (e.g. after a boundary drag marks the play dirty), and a
        // flipped first side re-labels every A/B column in the game. The pin
        // equals the current anchor, so nothing visibly changes now.
        guard serveOverrides[first.id] == nil else { return }
        let anchor = anchorSide(for: game) ?? .left
        recordEvent(.serveSideOverridden(pointID: first.id, side: anchor.rawValue))
    }

    /// Legend for a game: which physical side is A and which is B.
    func sideLegend(for game: Game) -> String? {
        guard let anchor = anchorSide(for: game), anchor != .unknown else { return nil }
        let aPhysical = serveSideLabel(anchor).lowercased()
        let bPhysical = serveSideLabel(anchor == .left ? .right : .left).lowercased()
        return "A = \(aPhysical) side · B = \(bPhysical) side"
    }

    /// Whether Side A is the top/left half of the frame (for the legend
    /// overlay on a real video frame).
    func sideAIsFirstHalf(for game: Game) -> Bool {
        (anchorSide(for: game) ?? .left) == .left
    }

    /// Manual winner correction, in the user's A/B vocabulary. Winner of play
    /// N = server of play N+1, so mid-game this pins the NEXT play's serve;
    /// only the match's final play needs its own winner event.
    func overrideWinner(pointID: UUID, winnerIsA: Bool) {
        guard let game = games.first(where: { $0.points.contains(where: { $0.id == pointID }) }) else { return }
        // Selecting the winner the app already believes is a no-op — say so
        // instead of silently recording pins. The wrong row is elsewhere.
        if let current = self.winnerIsA(of: pointID), current == winnerIsA {
            let number = point(withID: pointID)?.pointNumber ?? 0
            appendCorrectionLog("play #\(number): user CONFIRMED winner=\(winnerIsA ? "A" : "B") (no-op)\nmodel: \(scoreTraces[pointID] ?? "no trace")")
            statusMessage = "Play #\(number) is already scored for Side \(winnerIsA ? "A" : "B") — nothing changed. If the score still looks wrong, correct the play whose winner is wrong, or use Swap A↔B in the game legend if the sides are reversed."
            return
        }
        // Capture the model's belief BEFORE any pins rewrite provenance.
        let modelBelief = scoreTraces[pointID] ?? "no trace"
        let scoreBefore = pointScores[pointID].map { "\($0.scoreA):\($0.scoreB)" } ?? "—"
        // The user corrects THIS play against the chain they see above it —
        // make every earlier displayed winner durable first, so neither this
        // correction nor a later re-detection can ripple backward.
        pinDisplayedWinners(before: pointID)
        freezeAnchorIfNeeded(for: game)
        let anchor = anchorSide(for: game) ?? .left
        let winnerSide: ServeDetector.ServeSide = winnerIsA ? anchor : (anchor == .left ? .right : .left)

        let gameActive = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard let idx = gameActive.firstIndex(where: { $0.id == pointID }) else { return }
        let number0 = point(withID: pointID)?.pointNumber ?? 0
        if idx < gameActive.count - 1 {
            let next = gameActive[idx + 1]
            appendCorrectionLog("""
                CORRECTION play #\(number0) (\(String(format: "%.1f", gameActive[idx].start))s)
                model said: \(modelBelief)  [displayed \(scoreBefore)]
                user said:  winner=\(winnerIsA ? "A" : "B")
                deciding serve (next play #\(next.pointNumber)) was: \(serveProvenance(next.id))
                recorded: pin serve of #\(next.pointNumber) = \(winnerSide.rawValue)
                """)
            recordEvent(.serveSideOverridden(pointID: next.id, side: winnerSide.rawValue))
        } else {
            // Last play of ITS game gets an explicit winner event — pinning
            // the next game's first serve would re-anchor that game's A/B.
            appendCorrectionLog("""
                CORRECTION play #\(number0) (final play of its game)
                model said: \(modelBelief)  [displayed \(scoreBefore)]
                user said:  winner=\(winnerIsA ? "A" : "B")
                recorded: explicit final-play winner = \(winnerSide.rawValue)
                """)
            recordEvent(.pointWinnerOverridden(pointID: pointID, side: winnerSide.rawValue))
        }
        computeAllScores()
        if let number = point(withID: pointID)?.pointNumber {
            statusMessage = "Play #\(number) winner set to Side \(winnerIsA ? "A" : "B") — scores recalculated."
        }
    }

    /// Record the currently displayed winner of every active play BEFORE the
    /// given one as durable overrides: plays whose winner rests on a guessed
    /// (undetected) next serve get that serve pinned, and game-final plays
    /// get an explicit winner event. Every pin equals what is already on
    /// screen, so nothing visibly moves — the rows above a correction are
    /// simply frozen against backward ripple and future re-detection.
    private func pinDisplayedWinners(before pointID: UUID) {
        let all = activePoints
        guard let limit = all.firstIndex(where: { $0.id == pointID }) else { return }
        for k in 0..<limit {
            let p = all[k]
            guard let isA = winnerIsA(of: p.id),
                  let game = games.first(where: { $0.points.contains(where: { $0.id == p.id }) }),
                  let anchor = anchorSide(for: game), anchor != .unknown else { continue }
            let winnerSide: ServeDetector.ServeSide = isA ? anchor : (anchor == .left ? .right : .left)
            let gameActive = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
            guard let gi = gameActive.firstIndex(where: { $0.id == p.id }) else { continue }
            if gi < gameActive.count - 1 {
                // Pin DETECTED serves too, not just missing ones: a detected
                // side can be overwritten by later re-detection (dirty plays),
                // which would rewrite this row. The pin equals the displayed
                // winner, so nothing visibly changes.
                let next = gameActive[gi + 1]
                if serveOverrides[next.id] == nil {
                    recordEvent(.serveSideOverridden(pointID: next.id, side: winnerSide.rawValue))
                }
            } else if winnerOverrides[p.id] == nil {
                recordEvent(.pointWinnerOverridden(pointID: p.id, side: winnerSide.rawValue))
            }
        }
    }

    /// The sides are labeled backwards for a whole game (A should be B):
    /// re-anchor by pinning the first play's serve to the opposite side.
    /// Every row's A/B letter and both score columns swap; the winner of
    /// each play (as a physical party) is unchanged.
    func swapSides(for game: Game) {
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard let first = active.first else { return }
        let anchor = anchorSide(for: game) ?? .left
        let flipped: ServeDetector.ServeSide = anchor == .left ? .right : .left
        appendCorrectionLog("SWAP A↔B game \(game.gameNumber): anchor \(anchor.rawValue) → \(flipped.rawValue) (user says labels were reversed)")
        recordEvent(.serveSideOverridden(pointID: first.id, side: flipped.rawValue))
        computeAllScores()
        statusMessage = "A and B swapped for game \(game.gameNumber) — Side A is now the \(serveSideLabel(flipped).lowercased()) side."
    }

    /// Rules violation for a game's score chain, if any (e.g. 23:9).
    func scoreViolation(for game: Game) -> String? {
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        let ordered = active.compactMap { point in
            pointScores[point.id].map { (pointID: point.id, score: $0) }
        }
        guard ordered.count == active.count else { return nil }
        return ScoreValidator.firstViolation(orderedScores: ordered)?.reason
    }

    /// Game separator: this play starts a new game. Ledger correction (⌘Z).
    func startNewGame(atPointID pointID: UUID) {
        guard let target = point(withID: pointID) else { return }
        recordEvent(.gameSplitInserted(beforePointID: pointID))
        rematerializeFromSession()
        statusMessage = "New game starts at \(String(format: "%d:%02d", Int(target.start) / 60, Int(target.start) % 60)) — scores restart 0:0 there. ⌘Z to undo."
    }

    /// The user's hint flow: given the TRUE final score, re-analyze serve
    /// confidence and flip the least-confident winner attributions (never
    /// user-pinned ones) until the chain reaches it.
    func correctFinalScore(gameID: UUID, targetA: Int, targetB: Int) {
        guard let game = games.first(where: { $0.id == gameID }), let url = currentAssetURL else { return }
        let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
        guard targetA >= 0, targetB >= 0, targetA + targetB == active.count else {
            statusMessage = "\(targetA):\(targetB) totals \(targetA + targetB) plays but this game has \(active.count) — fix plays first (delete/add), then correct the score."
            return
        }
        freezeAnchorIfNeeded(for: game)
        statusMessage = "Analyzing serve confidence to reconcile the score…"
        let allActive = activePoints
        Task {
            let detection = await ServeDetector.detectServesWithConfidence(videoURL: url, points: allActive)
            guard self.currentAssetURL == url else { return }

            let winners = active.map { self.winnerIsA(of: $0.id) }
            let currentA = winners.filter { $0 == true }.count
            let delta = currentA - targetA
            guard delta != 0 else {
                self.statusMessage = "Score already matches \(targetA):\(targetB)."
                return
            }

            // Confidence of winner(i) = detection margin of the play that
            // serves next; pinned = any user override involved.
            var margins: [Double] = []
            var pinned: [Bool] = []
            for (i, playPoint) in active.enumerated() {
                if let globalIdx = allActive.firstIndex(where: { $0.id == playPoint.id }),
                   globalIdx < allActive.count - 1 {
                    let next = allActive[globalIdx + 1]
                    margins.append(detection.margins[next.id] ?? 0)
                    pinned.append(self.serveOverrides[next.id] != nil || self.winnerOverrides[playPoint.id] != nil)
                } else {
                    margins.append(.greatestFiniteMagnitude)
                    pinned.append(self.winnerOverrides[playPoint.id] != nil)
                }
                _ = i
            }

            let flips = ScoreValidator.chooseFlips(winnersIsA: winners, margins: margins, pinned: pinned, delta: delta)
            guard flips.count == abs(delta) else {
                self.statusMessage = "Couldn't reconcile automatically — only \(flips.count) adjustable plays found (\(abs(delta)) needed). Pin winners manually via right-click."
                return
            }

            let flipToA = delta < 0
            for idx in flips {
                let playPoint = active[idx]
                let anchor = self.anchorSide(for: game) ?? .left
                let winnerSide: ServeDetector.ServeSide = flipToA ? anchor : (anchor == .left ? .right : .left)
                if let globalIdx = allActive.firstIndex(where: { $0.id == playPoint.id }), globalIdx < allActive.count - 1 {
                    self.recordEvent(.serveSideOverridden(pointID: allActive[globalIdx + 1].id, side: winnerSide.rawValue))
                } else {
                    self.recordEvent(.pointWinnerOverridden(pointID: playPoint.id, side: winnerSide.rawValue))
                }
            }
            let flipLines = flips.map { idx in
                "  flip play #\(active[idx].pointNumber): model winner=\(winners[idx] == true ? "A" : winners[idx] == false ? "B" : "?") margin=\(String(format: "%.4f", margins[idx])) → user chain needs \(flipToA ? "A" : "B")"
            }.joined(separator: "\n")
            self.appendCorrectionLog("RECONCILE game \(game.gameNumber) to true final score \(targetA):\(targetB) (delta \(delta))\n\(flipLines)")
            self.computeAllScores()
            let numbers = flips.map { "#\(active[$0].pointNumber)" }.sorted().joined(separator: ", ")
            self.statusMessage = "Flipped the least-confident winners (\(numbers)) → \(targetA):\(targetB). Review them — each is undoable via right-click or ⌘Z."
        }
    }

    /// The A/B label for one side within the game containing a point.
    func serveABLabel(_ side: ServeDetector.ServeSide, forPointID pointID: UUID) -> String {
        guard let game = games.first(where: { $0.points.contains(where: { $0.id == pointID }) }) else {
            return serveSideLabel(side)
        }
        let labels = serveMenuLabels(for: game)
        return side == .right ? labels.right : labels.left
    }

    /// The serve side scoring will use for a point (override beats detection).
    func effectiveServeSide(for pointID: UUID) -> ServeDetector.ServeSide? {
        serveOverrides[pointID] ?? serveSides[pointID]
    }

    /// Manual score fix: pin a point's serve side (ledger-recorded; wins over
    /// re-detection permanently) and recompute the score chain.
    func overrideServeSide(pointID: UUID, side: ServeDetector.ServeSide) {
        recordEvent(.serveSideOverridden(pointID: pointID, side: side.rawValue))
        computeAllScores()
        statusMessage = "Serve pinned to \(serveABLabel(side, forPointID: pointID)) — scores recalculated."
    }

    /// Points whose start moved since their serve side was detected.
    private var serveDirtyIDs: Set<UUID> = []
    private var serveRedetectTask: Task<Void, Never>?

    /// Incrementally re-detect serve sides for points that are new (splits,
    /// adds, merges) or whose start moved — the serve frame decides which
    /// party won, so stale/missing sides corrupt the running score.
    func scheduleServeRedetection() {
        serveRedetectTask?.cancel()
        guard let url = currentAssetURL else { return }
        serveRedetectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled, self.currentAssetURL == url else { return }
            let active = self.activePoints
            let dirty = active.filter {
                self.serveOverrides[$0.id] == nil
                    && (self.serveSides[$0.id] == nil || self.serveDirtyIDs.contains($0.id))
            }
            guard !dirty.isEmpty else { return }
            self.statusMessage = "Re-detecting serve parties for \(dirty.count) play\(dirty.count == 1 ? "" : "s") with the vision model…"

            // Detect over ALL active plays: the classifier splits sides
            // around the centroid distribution's median, so a small or
            // one-sided subset would mis-split. Fresh results are applied
            // only to the dirty plays; manual pins stay untouched.
            let detection = await ServeDetector.detectServesWithConfidence(videoURL: url, points: active)
            guard !Task.isCancelled, self.currentAssetURL == url else { return }
            self.serveAxis = detection.axis
            self.serveMargins.merge(detection.margins) { _, new in new }
            for point in dirty {
                if let side = detection.sides[point.id] {
                    self.serveSides[point.id] = side
                }
            }
            self.serveDirtyIDs.subtract(dirty.map(\.id))
            self.computeAllScores()
            self.statusMessage = "Serve parties re-detected (\(dirty.count) play\(dirty.count == 1 ? "" : "s")) — scores recalculated."
            if var baseline = self.sessionBaseline {
                baseline.serveSides = self.serveSides
                baseline.serveAxis = detection.axis
                self.sessionBaseline = baseline
                self.sessionStore.rewriteBaseline(baseline, for: url)
            }
        }
    }

    func detectServesAndScores() {
        guard let url = currentAssetURL, !games.isEmpty else { return }
        let allPoints = games.flatMap(\.points)

        Task {
            let detection = await ServeDetector.detectServesWithConfidence(videoURL: url, points: allPoints)
            self.serveSides = detection.sides
            self.serveAxis = detection.axis
            self.serveMargins = detection.margins
            computeAllScores()

            // Serve detection finishes after the baseline is saved — fold the
            // sides into the persisted baseline so restored sessions have them.
            if var baseline = sessionBaseline {
                baseline.serveSides = detection.sides
                baseline.serveAxis = detection.axis
                sessionBaseline = baseline
                sessionStore.rewriteBaseline(baseline, for: url)
            }
        }
    }

    func computeAllScores() {
        var allScores: [UUID: ServeDetector.PointScore] = [:]

        for (gameIdx, game) in games.enumerated() {
            // For the last point of this game, check first serve of next game
            let nextGameFirstServe: ServeDetector.ServeSide?
            if gameIdx < games.count - 1 {
                let nextGameActivePoint = games[gameIdx + 1].points.first { $0.reviewStatus != .deleted }
                nextGameFirstServe = nextGameActivePoint.flatMap { effectiveServeSide(for: $0.id) }
            } else {
                nextGameFirstServe = nil
            }

            let lastActive = game.points.filter { $0.reviewStatus != .deleted }
                .max(by: { $0.start < $1.start })
            let result = ServeDetector.computeScoresWithTrace(
                points: game.points,
                serveSides: serveSides.merging(serveOverrides) { _, manual in manual },
                nextGameFirstServe: nextGameFirstServe,
                firstServe: anchorSide(for: game),
                lastPointWinner: lastActive.flatMap { winnerOverrides[$0.id] }
            )
            allScores.merge(result.scores) { _, new in new }
            scoreTraces.merge(result.trace) { _, new in new }
        }

        pointScores = allScores
        refreshHighlightScores()
        writeScoreDiagnosticsLog()
    }

    /// Per-play winner-derivation traces from the last score computation.
    private var scoreTraces: [UUID: String] = [:]
    /// Detection confidence margins from the last serve-detection pass.
    private var serveMargins: [UUID: Double] = [:]

    /// One play's serve side with provenance and confidence, for diagnostics.
    private func serveProvenance(_ id: UUID) -> String {
        if let o = serveOverrides[id] { return "\(o.rawValue)[PINNED]" }
        if let d = serveSides[id] {
            let m = serveMargins[id].map { String(format: " m=%.4f", $0) } ?? ""
            return "\(d.rawValue)[detected\(m)]"
        }
        return "—[missing]"
    }

    /// Append-only correction audit: every manual score action captures the
    /// model's belief (evidence + margin) vs the user's truth, so wrong
    /// judgments can be analyzed later against /tmp/serve_detection_log.txt.
    private func appendCorrectionLog(_ entry: String) {
        appendToLog("=== \(Date())\n\(entry)\n", path: "/tmp/score_corrections_log.txt")
    }

    /// Human-readable dump of the whole winner-detection chain, rewritten on
    /// every score computation: per game the anchor and its source, per play
    /// the serve side + provenance (pinned/detected/missing) and the exact
    /// evidence that decided its winner. The raw classifier internals
    /// (centroids, split, margins) land in /tmp/serve_detection_log.txt.
    private func writeScoreDiagnosticsLog() {
        var lines: [String] = []
        lines.append("════════ SCORE CALCULATION RUN — \(Date()) ════════")
        lines.append("video: \(currentAssetURL?.lastPathComponent ?? "?")  axis: \(serveAxis == .vertical ? "vertical (far|near)" : "horizontal (left|right)")")
        lines.append("rule: winner(N) = server(N+1); A = side serving each game's first play; display A:B")

        for game in games {
            let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
            guard !active.isEmpty else { continue }
            let anchor = anchorSide(for: game)
            let anchorSource: String
            if let first = active.first {
                if serveOverrides[first.id] != nil { anchorSource = "first play PINNED" }
                else if serveSides[first.id] != nil, serveSides[first.id] != .unknown { anchorSource = "first play detected" }
                else { anchorSource = "FALLBACK: earliest known side (first play unknown)" }
            } else { anchorSource = "?" }
            lines.append("")
            lines.append("GAME \(game.gameNumber): A = \(anchor.map { serveSideLabel($0).lowercased() } ?? "?") side (\(anchorSource))")
            if let v = scoreViolation(for: game) { lines.append("  ⚠️ RULES VIOLATION: \(v)") }

            for point in active {
                let score = pointScores[point.id].map { "\($0.scoreA):\($0.scoreB)" } ?? "—"
                let trace = scoreTraces[point.id] ?? "no trace"
                lines.append(String(format: "#%-3d %6.1fs–%6.1fs  serve=%@  %@  → %@",
                                    point.pointNumber, point.start, point.end,
                                    serveProvenance(point.id), trace, score))
            }
        }
        appendToLog(lines.joined(separator: "\n") + "\n", path: "/tmp/score_detection_log.txt")
    }

    /// Append-only log writer: every run is kept, nothing is overwritten.
    private func appendToLog(_ text: String, path: String) {
        let block = "\n" + text
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(block.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? block.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Recompute highlight scores for the active points: the promoted personal
    /// ranker when one exists, else the built-in heuristic weights.
    func refreshHighlightScores() {
        let activePoints = games.flatMap(\.points).filter { $0.reviewStatus != .deleted }
        var base: [UUID: Double]?
        if let model = loadedRankerModel() {
            let vectors = HighlightScorer.percentileFeatureVectors(points: activePoints, frames: featureFrames, onsets: audioSignals.onsets)
            var scores: [UUID: Double] = [:]
            var failed = false
            for (id, vector) in vectors {
                if let score = HighlightRanker.predict(model: model, features: vector) {
                    scores[id] = score
                } else {
                    failed = true
                    break
                }
            }
            if !failed { base = scores }
        }
        let resolved = base ?? HighlightScorer.scores(points: activePoints, frames: featureFrames, onsets: audioSignals.onsets)
        highlightScores = HighlightScorer.applyingCheer(to: resolved, points: activePoints, timeline: audioSignals.cheer)
    }

    // MARK: - Trim Segments

    func deriveTrimSegments() {
        if !games.isEmpty {
            // Derive trims from gaps between active points
            let activeSegments = games.flatMap(\.points)
                .filter { $0.reviewStatus != .deleted }
                .map(\.rallySegment)
                .sorted { $0.start < $1.start }

            let totalDuration = videoMetadata?.duration ?? sessionBaseline?.videoDuration ?? activeSegments.last?.end ?? 0
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

    /// Update a point's rally segment start or end time. Clamped against the
    /// video bounds AND the neighboring active points, so no edit path can
    /// create overlapping points.
    func updatePointBoundary(pointID: UUID, newStart: TimeInterval? = nil, newEnd: TimeInterval? = nil) {
        let duration = videoMetadata?.duration ?? .infinity
        let limits = boundaryLimits(for: pointID)
        for gameIdx in games.indices {
            if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                if let ns = newStart {
                    let minStart = max(0, max(ns, limits.minStart))
                    let maxStart = games[gameIdx].points[pointIdx].rallySegment.end - 0.5
                    games[gameIdx].points[pointIdx].rallySegment.start = min(minStart, maxStart)
                }
                if let ne = newEnd {
                    let maxEnd = min(min(duration, limits.maxEnd), ne)
                    let minEnd = games[gameIdx].points[pointIdx].rallySegment.start + 0.5
                    games[gameIdx].points[pointIdx].rallySegment.end = max(maxEnd, minEnd)
                }
                return
            }
        }
    }

    /// Manual-drag variant of updatePointBoundary: crossing a neighboring
    /// active point PUSHES that neighbor's boundary along (ripple) instead of
    /// stopping, capped so the neighbor keeps at least 0.5s. The pushed
    /// neighbor must be committed by the caller on release (see tune handles).
    func updatePointBoundaryPushing(pointID: UUID, newStart: TimeInterval? = nil, newEnd: TimeInterval? = nil) {
        guard let target = point(withID: pointID) else { return }
        let active = activePoints
        if let ns = newStart,
           let prev = active.last(where: { $0.end <= target.start + 0.01 && $0.id != pointID }),
           ns < prev.end {
            updatePointBoundary(pointID: prev.id, newEnd: max(prev.start + 0.5, ns))
        }
        if let ne = newEnd,
           let next = active.first(where: { $0.start >= target.end - 0.01 && $0.id != pointID }),
           ne > next.start {
            updatePointBoundary(pointID: next.id, newStart: min(next.end - 0.5, ne))
        }
        updatePointBoundary(pointID: pointID, newStart: newStart, newEnd: newEnd)
    }

    /// Restore chronological order + numbering after boundary edits.
    func resortAndRenumberPoints() {
        for gameIdx in games.indices {
            games[gameIdx].points.sort { $0.start < $1.start }
            for i in games[gameIdx].points.indices {
                games[gameIdx].points[i].pointNumber = i + 1
            }
        }
    }

    /// Active points that overlap their predecessor — surfaced as a warning
    /// so historical overlaps (from before neighbor clamping) get repaired.
    var overlappingPointIDs: Set<UUID> {
        var result: Set<UUID> = []
        for game in games {
            let active = game.points.filter { $0.reviewStatus != .deleted }.sorted { $0.start < $1.start }
            for i in 1..<max(1, active.count) where active[i].start < active[i - 1].end - 0.05 {
                result.insert(active[i].id)
                result.insert(active[i - 1].id)
            }
        }
        return result
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

                statusMessage = "Analyzing audio (onsets + crowd)..."
                self.audioSignals = await AudioSignalExtractor.extract(from: url)

                analysisProgress.stage = .finalizing
                let classifier = HybridSegmenter()
                let rawSegments = classifier.classify(frames: frames, config: config)
                let processed = classifier.postProcess(segments: rawSegments, frames: frames, config: config)
                let taRefined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
                // Clean up TA artifacts: remove 0-duration segments, merge consecutive same-label
                let refined = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(taRefined), maxGap: 0.5)
                self.segments = refined

                deriveGameStructure()
                deriveTrimSegments()
                refreshHighlightScores()
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

                // Persist the re-analysis as the new session baseline
                persistBaseline(for: url)
                sessionStore.saveAudioSignals(audioSignals, for: url)
                saveCurrentVideoState()
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

    // MARK: - Training Pool

    func refreshTrainingPool() {
        let manifest = HitModelTrainer.loadManifest()
        trainingPoolManifest = manifest
        if manifest.videos.isEmpty {
            trainingPoolStatus = .empty
        } else {
            trainingPoolStatus = .hasData(manifest: manifest)
        }
    }

    /// Whether the currently loaded video is already in the training pool.
    var currentVideoInPool: Bool {
        guard let url = currentAssetURL else { return false }
        let baseName = url.deletingPathExtension().lastPathComponent
        return trainingPoolManifest.videos.contains { $0.videoFileName == baseName }
    }

    func saveTrainingClips() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        guard !games.isEmpty else {
            lastErrorMessage = "Analyze a video and review points before saving."
            return
        }

        trainingPoolStatus = .saving(progress: "Starting...")

        Task {
            do {
                let entry = try await HitModelTrainer.saveTrainingClips(
                    videoURL: url,
                    games: games,
                    featureFrames: self.featureFrames,
                    progress: { [weak self] msg in
                        Task { @MainActor [weak self] in
                            self?.trainingPoolStatus = .saving(progress: msg)
                        }
                    }
                )
                refreshTrainingPool()
                statusMessage = "Saved \(entry.rallyClipCount) rally + \(entry.backgroundClipCount) background clips from \(entry.videoFileName)"
                recordEvent(.savedToPool(rallyClips: entry.rallyClipCount, backgroundClips: entry.backgroundClipCount))
            } catch {
                refreshTrainingPool()
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func trainFromPool() {
        hitModelStatus = .training(progress: "Starting...")

        Task {
            do {
                // Train to a scratch location; the registry owns the file after addVersion.
                let candidateURL = hitModelOutputURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("candidate_hit_classifier.mlmodelc")
                try? FileManager.default.removeItem(at: candidateURL)

                let result = try await HitModelTrainer.trainFromPool(
                    outputModelURL: candidateURL,
                    progress: { [weak self] msg in
                        Task { @MainActor [weak self] in
                            self?.hitModelStatus = .training(progress: msg)
                        }
                    }
                )

                var meta = try hitModelRegistry.addVersion(
                    compiledModelAt: candidateURL,
                    clipCount: result.clipCount,
                    trainingAccuracy: result.accuracy
                )

                // Shadow eval (D-007 complete): re-score each corrected
                // session's AUDIO with the candidate model, replay the
                // pipeline, and score against the user's corrections. The
                // current model is evaluated the same way for a like-for-like
                // gate; stored metrics are the fallback when it can't be.
                hitModelStatus = .training(progress: "Shadow-evaluating candidate vs current (audio re-scored)…")
                let config = AnalysisConfig(
                    rallyPercentile: sensitivity.rallyPercentile,
                    motionWeight: sensitivity.motionWeight,
                    audioWeight: sensitivity.audioWeight
                )
                let store = sessionStore
                let candidateModelURL = hitModelRegistry.modelURL(forVersion: meta.version)
                let currentModelURL = hitModelRegistry.currentModelURL()
                let candidateMetrics = await Task.detached {
                    await ShadowEvaluator.evaluateCorpus(store: store, config: config, audioModelURL: candidateModelURL)
                }.value
                let currentFresh: ShadowEvalMetrics? = await {
                    guard let currentModelURL else { return nil }
                    return await Task.detached {
                        await ShadowEvaluator.evaluateCorpus(store: store, config: config, audioModelURL: currentModelURL)
                    }.value
                }()

                let currentMeta = hitModelRegistry.currentVersion()
                    .flatMap { hitModelRegistry.metadata(forVersion: $0) }
                let decision = ShadowEval.gate(candidate: candidateMetrics, current: currentFresh ?? currentMeta?.shadowEval)
                meta.shadowEval = candidateMetrics
                meta.gateDecision = decision
                try? hitModelRegistry.save(meta)

                if decision.promote {
                    hitModelRegistry.promote(version: meta.version)
                    hitModelStatus = .trained(accuracy: result.accuracy, clipCount: result.clipCount)
                    statusMessage = "\(meta.versionLabel) trained and promoted — \(decision.reason)"
                } else if let currentMeta {
                    hitModelStatus = .trained(accuracy: currentMeta.trainingAccuracy, clipCount: currentMeta.clipCount)
                    statusMessage = "\(meta.versionLabel) trained but NOT promoted — \(decision.reason)"
                } else {
                    hitModelStatus = .notTrained
                    statusMessage = "\(meta.versionLabel) trained but NOT promoted — \(decision.reason)"
                }
                refreshHitModelVersions()
            } catch {
                hitModelStatus = .failed(error: error.localizedDescription)
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Point the pipeline at a specific version (promote a held candidate or
    /// revert to an older one).
    func promoteHitModel(version: Int) {
        hitModelRegistry.promote(version: version)
        refreshHitModelVersions()
        if let meta = hitModelRegistry.metadata(forVersion: version) {
            hitModelStatus = .trained(accuracy: meta.trainingAccuracy, clipCount: meta.clipCount)
        }
        statusMessage = String(format: "Now using hit model v%03d. Re-analyze to apply.", version)
    }

    func deleteHitModel() {
        hitModelRegistry.removeAll()
        refreshHitModelVersions()
        hitModelStatus = .notTrained
        statusMessage = "All hit model versions deleted."
    }

    func clearTrainingPool() {
        HitModelTrainer.clearTrainingPool()
        refreshTrainingPool()
        statusMessage = "Training data cleared."
    }

    // MARK: - Export

    /// Active points in chronological order (the scoring-reel selection).
    var activePoints: [GamePoint] {
        games.flatMap(\.points)
            .filter { $0.reviewStatus != .deleted }
            .sorted { $0.start < $1.start }
    }

    /// The highlight reel's points under the current plan.
    var highlightReelPoints: [GamePoint] {
        HighlightScorer.select(points: activePoints, scores: highlightScores, selection: exportPlan.highlightSelection)
    }

    /// Build the file list for the current plan. Individual clips cover every
    /// point that appears in any selected reel.
    func exportJobs(for url: URL) -> [ExportJob] {
        let base = url.deletingPathExtension()
        var jobs: [ExportJob] = []

        let scoringSegments = effectiveKeptSegments
        let highlights = highlightReelPoints
        let fade: TimeInterval = exportPlan.transition == .crossfade ? 0.5 : 0

        if exportPlan.reels.contains(.scoring), !scoringSegments.isEmpty {
            // Score overlay needs per-point alignment; only possible when the
            // game structure exists (segments == active points' rally segments).
            let active = activePoints
            var overlays: [String?]?
            if exportPlan.scoreOverlay, !active.isEmpty, active.count == scoringSegments.count {
                overlays = active.map { pointScores[$0.id]?.display }
            }
            jobs.append(ExportJob(
                label: "Scoring reel",
                outputURL: base.appendingPathExtension("scoring.mov"),
                segments: scoringSegments,
                overlayTexts: overlays,
                crossfade: fade
            ))
        }
        if exportPlan.reels.contains(.highlights), !highlights.isEmpty {
            jobs.append(ExportJob(
                label: "Highlight reel",
                outputURL: base.appendingPathExtension("highlights.mov"),
                segments: highlights.map(\.rallySegment),
                crossfade: fade
            ))
        }
        if exportPlan.individualClips {
            var clipPoints = exportPlan.reels.contains(.scoring) ? activePoints : []
            if exportPlan.reels.contains(.highlights) {
                for point in highlights where !clipPoints.contains(where: { $0.id == point.id }) {
                    clipPoints.append(point)
                }
            }
            let clipsDir = base.appendingPathExtension("clips")
            let gameByPoint: [UUID: Int] = Dictionary(uniqueKeysWithValues: games.flatMap { game in
                game.points.map { ($0.id, game.gameNumber) }
            })
            for point in clipPoints.sorted(by: { $0.start < $1.start }) {
                let game = gameByPoint[point.id] ?? 1
                jobs.append(ExportJob(
                    label: String(format: "Clip G%d #%02d", game, point.pointNumber),
                    outputURL: clipsDir.appendingPathComponent(String(format: "G%d_point%02d.mov", game, point.pointNumber)),
                    segments: [point.rallySegment]
                ))
            }
        }
        return jobs
    }

    func runExport() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        let jobs = exportJobs(for: url)
        guard !jobs.isEmpty else {
            lastErrorMessage = "Nothing to export — enable a reel and run analysis first."
            return
        }
        if exportPlan.individualClips {
            try? FileManager.default.createDirectory(
                at: url.deletingPathExtension().appendingPathExtension("clips"),
                withIntermediateDirectories: true
            )
        }

        isExporting = true
        exportOutputs = []
        statusMessage = "Exporting…"
        lastErrorMessage = nil

        Task {
            do {
                let outputs = try await exporter.run(
                    jobs: jobs,
                    assetURL: url,
                    matchSourceFormat: exportPlan.matchSourceFormat,
                    onProgress: { [weak self] message in self?.statusMessage = message }
                )
                exportOutputs = outputs
                let reels = outputs.filter { !$0.label.hasPrefix("Clip") }
                let clipCount = outputs.count - reels.count
                var parts = reels.map(\.label)
                if clipCount > 0 { parts.append("\(clipCount) clips") }
                statusMessage = "Exported \(parts.joined(separator: " + "))"
                for output in reels {
                    recordEvent(.exported(output: output.url.lastPathComponent))
                }
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
