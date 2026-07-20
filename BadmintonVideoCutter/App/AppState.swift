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
    @Published var canUndo = false
    @Published var canRedo = false
    /// Points inserted by the user (effective `pointAdded` corrections).
    @Published var addedPointIDs: Set<UUID> = []
    /// Points whose boundaries were adjusted (effective `boundaryChanged` corrections).
    @Published var editedPointIDs: Set<UUID> = []
    /// Latest 👍/👎 per point, derived from `highlightRated` events.
    @Published var pointRatings: [UUID: HighlightRating] = [:]
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
    func refreshRankerRatingCount() {
        let store = sessionStore
        let root = store.root
        Task {
            let count = await Task.detached {
                HighlightRanker.collectSamples(store: store, sessionsRoot: root).count
            }.value
            rankerRatingCount = count
        }
    }

    func trainHighlightRanker() {
        isTrainingRanker = true
        statusMessage = "Training highlight ranker…"
        let store = sessionStore
        let root = store.root

        Task {
            do {
                let samples = await Task.detached {
                    HighlightRanker.collectSamples(store: store, sessionsRoot: root)
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

                if decision.promote {
                    rankerRegistry.promote(version: meta.version)
                    statusMessage = "Ranker \(meta.versionLabel) trained and promoted — \(decision.reason)"
                } else {
                    statusMessage = "Ranker \(meta.versionLabel) trained but NOT promoted — \(decision.reason)"
                }
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

        sessionBaseline = loaded.baseline
        sessionEvents = loaded.events
        segments = loaded.baseline.segments
        featureFrames = loaded.frames
        audioSignals = loaded.audioSignals ?? AudioSignals()
        serveSides = loaded.baseline.serveSides

        let effective = SessionMaterializer.effectiveCorrections(from: loaded.events)
        games = SessionMaterializer.apply(events: effective, to: loaded.baseline.games)

        deriveTrimSegments()
        computeAllScores()
        refreshSessionDerivedState()

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
                let gameCount = games.count
                statusMessage = "Analysis complete\(mlStatus): \(rallyCount) points in \(gameCount) game\(gameCount == 1 ? "" : "s") (\(formatElapsed(elapsed)))"

                // Persist the analysis as the session baseline (corrections ledger)
                persistBaseline(for: analyzingURL)
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
        sessionStore.append(event, for: url)
        refreshSessionDerivedState()
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
        for event in sessionEvents {
            if case .highlightRated(let pointID, let raw) = event {
                if let rating = HighlightRating(rawValue: raw) {
                    ratings[pointID] = rating
                } else {
                    ratings.removeValue(forKey: pointID)
                }
            }
        }
        pointRatings = ratings
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
        refreshHighlightScores()
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
    }

    /// Persist a fresh analysis result as the session baseline.
    private func persistBaseline(for url: URL) {
        sessionBaseline = sessionStore.saveBaseline(
            segments: segments,
            games: games,
            serveSides: serveSides,
            videoDuration: videoMetadata?.duration,
            frames: featureFrames,
            usedHitModel: hitModelURL != nil,
            for: url
        )
        sessionEvents = []
        refreshSessionDerivedState()
    }

    // MARK: - Serve Detection & Scoring

    func detectServesAndScores() {
        guard let url = currentAssetURL, !games.isEmpty else { return }
        let allPoints = games.flatMap(\.points)

        Task {
            let sides = await ServeDetector.detectServes(videoURL: url, points: allPoints)
            self.serveSides = sides
            computeAllScores()

            // Serve detection finishes after the baseline is saved — fold the
            // sides into the persisted baseline so restored sessions have them.
            if var baseline = sessionBaseline {
                baseline.serveSides = sides
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
        refreshHighlightScores()
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

                // Shadow eval: replay every corrected session's cached frames
                // and score against the user's corrections (DESIGN §3.5).
                hitModelStatus = .training(progress: "Shadow-evaluating against corrected sessions…")
                let config = AnalysisConfig(
                    rallyPercentile: sensitivity.rallyPercentile,
                    motionWeight: sensitivity.motionWeight,
                    audioWeight: sensitivity.audioWeight
                )
                let store = sessionStore
                let sessionsRoot = store.root
                let candidateMetrics = await Task.detached {
                    ShadowEvaluator.evaluateCorpus(store: store, sessionsRoot: sessionsRoot, config: config)
                }.value

                let currentMeta = hitModelRegistry.currentVersion()
                    .flatMap { hitModelRegistry.metadata(forVersion: $0) }
                let decision = ShadowEval.gate(candidate: candidateMetrics, current: currentMeta?.shadowEval)
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
