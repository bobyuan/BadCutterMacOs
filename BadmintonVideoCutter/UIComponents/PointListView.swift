import SwiftUI
import AVFoundation
import Vision

struct PointListView: View {
    @ObservedObject var appState: AppState
    var selectedPointID: UUID?
    var playheadTime: TimeInterval = 0
    var onSelectPoint: ((GamePoint) -> Void)?
    var onFeedback: ((GamePoint, PointFeedbackReason) -> Void)?

    @State private var sortByScore = false
    @State private var showReanalyzeConfirm = false
    /// Batch verdicts (DESIGN §8.5): membership toggled by ⌘-click.
    @State private var batchSelection: Set<UUID> = []
    /// Score-fix flow: game being corrected + entered final score.
    @State private var fixScoreGame: Game?
    @State private var setScoreTarget: GamePoint?
    @State private var setScoreA = ""
    @State private var setScoreB = ""
    @State private var fixScoreA = ""
    @State private var fixScoreB = ""
    /// Game-separator confirmation.
    @State private var gameSplitCandidate: GamePoint?
    /// Legend popover: game whose A/B court frame is being shown.
    @State private var legendGameID: UUID?
    /// Detected court frame + player figures, keyed by the game's first
    /// active point ID (stable across re-materialization, unlike game IDs).
    @State private var legendCache: [UUID: LegendData] = [:]
    @State private var legendLoading: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Points")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 16)

            if appState.games.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No points detected")
                        .foregroundStyle(.secondary)
                    Text("Run analysis to detect points")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                let totalPoints = appState.games.reduce(0) { $0 + $1.activePointCount }
                let gameCount = appState.games.count
                HStack {
                    Text("\(totalPoints) points in \(gameCount) game\(gameCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !appState.runSummaries.isEmpty {
                        versionPill
                    }
                    Spacer()
                    Picker("", selection: $sortByScore) {
                        Text("Time").tag(false)
                        Text("Score").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal)

                if !appState.highlightScores.isEmpty, totalPoints > 1 {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Slider(
                            value: Binding(
                                get: { Double(min(appState.highlightTopK, totalPoints)) },
                                set: { appState.highlightTopK = Int($0.rounded()) }
                            ),
                            in: 1...Double(totalPoints),
                            step: 1
                        )
                        Text("Top \(min(appState.highlightTopK, totalPoints))")
                            .font(.caption).monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .help("Number of points marked as highlights")
                }

                if batchSelection.count >= 2 {
                    batchBar
                }

                if sortByScore {
                    scoreSortedList
                } else {
                    timeSortedList
                }

                saveForTrainingButton
            }
        }
        .alert(
            "Correct the final score",
            isPresented: Binding(get: { fixScoreGame != nil }, set: { if !$0 { fixScoreGame = nil } })
        ) {
            TextField("Side A", text: $fixScoreA)
            TextField("Side B", text: $fixScoreB)
            Button("Reconcile") {
                if let game = fixScoreGame, let a = Int(fixScoreA), let b = Int(fixScoreB) {
                    appState.correctFinalScore(gameID: game.id, targetA: a, targetB: b)
                }
                fixScoreGame = nil
            }
            Button("Cancel", role: .cancel) { fixScoreGame = nil }
        } message: {
            Text("Enter the real final score (A:B). The app re-analyzes serve confidence and flips only the least-confident winner calls — your pinned plays are never touched, and every flip is undoable.")
        }
        .alert(
            "Set score after play #\(setScoreTarget?.pointNumber ?? 0)",
            isPresented: Binding(get: { setScoreTarget != nil }, set: { if !$0 { setScoreTarget = nil } })
        ) {
            TextField("Side A", text: $setScoreA)
            TextField("Side B", text: $setScoreB)
            Button("Set score") {
                if let target = setScoreTarget, let a = Int(setScoreA), let b = Int(setScoreB) {
                    appState.adjustScore(pointID: target.id, scoreA: a, scoreB: b)
                }
                setScoreTarget = nil
            }
            Button("Cancel", role: .cancel) { setScoreTarget = nil }
        } message: {
            Text("The actual score right after this play (useful when the players themselves miscounted on court). Later plays continue counting from it; earlier plays are untouched.")
        }
        .confirmationDialog(
            "Start a new game here?",
            isPresented: Binding(get: { gameSplitCandidate != nil }, set: { if !$0 { gameSplitCandidate = nil } })
        ) {
            Button("Start new game from #\(gameSplitCandidate?.pointNumber ?? 0)") {
                if let point = gameSplitCandidate {
                    appState.startNewGame(atPointID: point.id)
                }
                gameSplitCandidate = nil
            }
            Button("Cancel", role: .cancel) { gameSplitCandidate = nil }
        } message: {
            Text("Plays from this one onward become a new game with a fresh 0:0 score and their own Side A (its first server). ⌘Z undoes.")
        }
        .alert("Re-analyze this video?", isPresented: $showReanalyzeConfirm) {
            Button("Re-analyze — keep history") { appState.analyzeCurrentVideo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let points = appState.games.reduce(0) { $0 + $1.activePointCount }
            let edits = appState.currentRunAdjustmentCount
            Text("Your current version (Analysis #\(appState.currentAnalysisRun) — \(points) points, \(edits) manual adjustment\(edits == 1 ? "" : "s")) will be kept in History. You can switch back anytime.")
        }
    }

    // MARK: - Version Pill

    /// Always-visible analysis version indicator + switcher. Turns orange
    /// when an older run is loaded.
    private var versionPill: some View {
        let latest = appState.runSummaries.last?.run ?? appState.currentAnalysisRun
        let isLatest = appState.currentAnalysisRun == latest
        return Menu {
            ForEach(appState.runSummaries.reversed()) { summary in
                Button {
                    appState.switchToRun(summary.run)
                } label: {
                    let mark = summary.run == appState.currentAnalysisRun ? "✓ " : ""
                    Text("\(mark)\(summary.label) — \(summary.savedAt.formatted(.dateTime.month().day())), \(summary.pointCount) pts")
                }
            }
            Divider()
            Button("Re-analyze…") { showReanalyzeConfirm = true }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                Text("Analysis #\(appState.currentAnalysisRun)\(isLatest ? "" : " (older)")")
                    .font(.caption)
            }
            .foregroundStyle(isLatest ? Color.secondary : Color.orange)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isLatest
              ? "Analysis versions — every re-analysis is kept; switch anytime"
              : "You are viewing an older analysis version")
    }

    // MARK: - Batch Verdicts (DESIGN §8.5)

    private var batchBar: some View {
        HStack(spacing: 8) {
            Text("\(batchSelection.count) selected")
                .font(.caption).bold()
            Button("Delete") { batchApply { appState.setPointReviewStatus(pointID: $0, status: .deleted) } }
                .controlSize(.small)
            Button("👍") { batchApply { appState.ratePoint(pointID: $0, rating: .up) } }
                .controlSize(.small)
            Button("👎") { batchApply { appState.ratePoint(pointID: $0, rating: .down) } }
                .controlSize(.small)
            Spacer()
            Button("Clear") { batchSelection.removeAll() }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Color.accentColor.opacity(0.1)))
    }

    private func batchApply(_ action: (UUID) -> Void) {
        for id in batchSelection { action(id) }
        batchSelection.removeAll()
    }

    /// ⌘-click toggles batch membership; a plain click clears the batch and
    /// previews as before.
    private func handleTap(on point: GamePoint) {
        if NSEvent.modifierFlags.contains(.command) {
            if batchSelection.contains(point.id) {
                batchSelection.remove(point.id)
            } else {
                batchSelection.insert(point.id)
            }
        } else {
            batchSelection.removeAll()
            onSelectPoint?(point)
        }
    }

    // MARK: - Lists

    private var timeSortedList: some View {
        List {
                    ForEach(appState.games) { game in
                        Section {
                            ForEach(game.points) { point in
                                PointRow(
                                    point: point,
                                    isSelected: point.id == selectedPointID,
                                    playheadTime: playheadTime,
                                    score: appState.pointScores[point.id],
                                    scoreBefore: appState.scoreBefore(of: point.id),
                                    chip: appState.reviewChip(for: point),
                                    rating: appState.pointRatings[point.id],
                                    highlightScore: appState.highlightScores[point.id],
                                    isTopHighlight: appState.topHighlightIDs.contains(point.id),
                                    onToggleDelete: {
                                        let newStatus: PointReviewStatus = point.reviewStatus == .deleted ? .unreviewed : .deleted
                                        appState.setPointReviewStatus(pointID: point.id, status: newStatus)
                                    },
                                    onRate: { rating in
                                        appState.ratePoint(pointID: point.id, rating: rating)
                                    },
                                    onFeedback: { reason in
                                        onFeedback?(point, reason)
                                    },
                                    isBatchSelected: batchSelection.contains(point.id),
                                    isOverlapping: appState.overlappingPointIDs.contains(point.id),
                                    winnerIsA: appState.winnerIsA(of: point.id),
                                    onOverrideWinner: { isA in
                                        appState.overrideWinner(pointID: point.id, winnerIsA: isA)
                                    },
                                    onStartNewGame: {
                                        gameSplitCandidate = point
                                    },
                                    onRecalculateScore: {
                                        appState.recalculateScores(fromPointID: point.id)
                                    },
                                    onSetScore: {
                                        setScoreTarget = point
                                        setScoreA = ""
                                        setScoreB = ""
                                    },
                                    onTap: {
                                        handleTap(on: point)
                                    }
                                )
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                GameSectionHeader(game: game, pointScores: appState.pointScores)
                                if let legend = appState.sideLegend(for: game) {
                                    HStack(spacing: 4) {
                                        if let key = legendKey(for: game), let data = legendCache[key] {
                                            legendMiniFigures(data)
                                        }
                                        Text(legend)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button {
                                            legendGameID = game.id
                                            loadLegendData(for: game)
                                        } label: {
                                            Image(systemName: "photo.circle")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Show the court with A/B labeled")
                                        .popover(isPresented: Binding(
                                            get: { legendGameID == game.id },
                                            set: { if !$0 { legendGameID = nil } }
                                        )) {
                                            legendPopover(for: game)
                                        }
                                        Button {
                                            appState.swapSides(for: game)
                                        } label: {
                                            Image(systemName: "arrow.left.arrow.right.circle")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("A and B are reversed — swap them for this game")
                                    }
                                    .onAppear { loadLegendData(for: game) }
                                }
                                if let violation = appState.scoreViolation(for: game) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                        Text(violation)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                        Button("Fix score…") {
                                            fixScoreGame = game
                                            fixScoreA = ""
                                            fixScoreB = ""
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption2)
                                    }
                                }
                            }
                        }

                        if game.breakAfter != nil && game.id != appState.games.last?.id {
                            Section {
                                HStack {
                                    Image(systemName: "pause.circle")
                                        .foregroundStyle(.blue)
                                    Text("Game break: \(formatDuration(game.breakAfter!.duration))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .listRowBackground(Color.blue.opacity(0.05))
                            }
                        }
                    }
        }
    }

    /// Flat ranking of active points by highlight score (highest first).
    private var scoreSortedList: some View {
        let ranked: [(game: Game, point: GamePoint)] = appState.games
            .flatMap { game in game.points.map { (game, $0) } }
            .filter { $0.1.reviewStatus != .deleted }
            .sorted { (appState.highlightScores[$0.1.id] ?? 0) > (appState.highlightScores[$1.1.id] ?? 0) }

        return List {
            ForEach(ranked, id: \.point.id) { entry in
                PointRow(
                    point: entry.point,
                    isSelected: entry.point.id == selectedPointID,
                    playheadTime: playheadTime,
                    score: appState.pointScores[entry.point.id],
                    scoreBefore: appState.scoreBefore(of: entry.point.id),
                    chip: appState.reviewChip(for: entry.point),
                    rating: appState.pointRatings[entry.point.id],
                    highlightScore: appState.highlightScores[entry.point.id],
                    isTopHighlight: appState.topHighlightIDs.contains(entry.point.id),
                    gameNumber: entry.game.gameNumber,
                    onToggleDelete: {
                        appState.setPointReviewStatus(pointID: entry.point.id, status: .deleted)
                    },
                    onRate: { rating in
                        appState.ratePoint(pointID: entry.point.id, rating: rating)
                    },
                    onFeedback: { reason in
                        onFeedback?(entry.point, reason)
                    },
                    isBatchSelected: batchSelection.contains(entry.point.id),
                    isOverlapping: appState.overlappingPointIDs.contains(entry.point.id),
                    winnerIsA: appState.winnerIsA(of: entry.point.id),
                    onOverrideWinner: { isA in
                        appState.overrideWinner(pointID: entry.point.id, winnerIsA: isA)
                    },
                    onStartNewGame: {
                        gameSplitCandidate = entry.point
                    },
                    onRecalculateScore: {
                        appState.recalculateScores(fromPointID: entry.point.id)
                    },
                    onSetScore: {
                        setScoreTarget = entry.point
                        setScoreA = ""
                        setScoreB = ""
                    },
                    onTap: {
                        handleTap(on: entry.point)
                    }
                )
            }
        }
    }

    // MARK: - Side Legend (real player figures from the video)

    private func legendKey(for game: Game) -> UUID? {
        game.points.first(where: { $0.reviewStatus != .deleted })?.id
    }

    @ViewBuilder
    private func legendPopover(for game: Game) -> some View {
        VStack(spacing: 8) {
            if let key = legendKey(for: game), let data = legendCache[key] {
                annotatedFrame(data)
                if !data.aFigures.isEmpty || !data.bFigures.isEmpty {
                    HStack(alignment: .top, spacing: 20) {
                        figureColumn(letter: "A", isA: true, figures: data.aFigures)
                        figureColumn(letter: "B", isA: false, figures: data.bFigures)
                    }
                } else {
                    Text("No players detected in this frame — court halves labeled instead.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(width: 440, height: 250)
            }
            Text("Side A served this game's first play. Scores read A:B.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Wrong way around? Swap A ↔ B") {
                appState.swapSides(for: game)
                legendGameID = nil
            }
            .font(.caption)
        }
        .padding(10)
    }

    /// The court frame with each detected player boxed and lettered in their
    /// side's color; falls back to half-labels when nobody was detected.
    private func annotatedFrame(_ data: LegendData) -> some View {
        Image(decorative: data.frame, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let sx = geo.size.width / CGFloat(data.frame.width)
                    let sy = geo.size.height / CGFloat(data.frame.height)
                    if data.boxes.isEmpty {
                        halfLabels(data)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        ForEach(Array(data.boxes.enumerated()), id: \.offset) { pair in
                            let box = pair.element
                            let r = CGRect(x: box.rect.minX * sx, y: box.rect.minY * sy,
                                           width: box.rect.width * sx, height: box.rect.height * sy)
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(box.isA ? Color.blue : Color.orange, lineWidth: 2)
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                            legendBadge(box.isA ? "A" : "B", isA: box.isA, size: 18)
                                .position(x: r.midX, y: max(10, r.minY - 11))
                        }
                    }
                }
            }
            .frame(width: 440, height: 250)
    }

    @ViewBuilder
    private func halfLabels(_ data: LegendData) -> some View {
        if data.vertical {
            VStack {
                legendBadge(data.aFirst ? "A" : "B", isA: data.aFirst)
                Spacer()
                legendBadge(data.aFirst ? "B" : "A", isA: !data.aFirst)
            }
            .padding(14)
        } else {
            HStack {
                legendBadge(data.aFirst ? "A" : "B", isA: data.aFirst)
                Spacer()
                legendBadge(data.aFirst ? "B" : "A", isA: !data.aFirst)
            }
            .padding(14)
        }
    }

    private func figureColumn(letter: String, isA: Bool, figures: [CGImage]) -> some View {
        VStack(spacing: 4) {
            legendBadge(letter, isA: isA, size: 22)
            HStack(spacing: 4) {
                ForEach(Array(figures.enumerated()), id: \.offset) { pair in
                    Image(decorative: pair.element, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(isA ? Color.blue : Color.orange, lineWidth: 2))
                }
                if figures.isEmpty {
                    Text("not seen")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Tiny cropped-player chips shown inline in the game header.
    private func legendMiniFigures(_ data: LegendData) -> some View {
        HStack(spacing: 3) {
            if let a = data.aFigures.first { miniFigureChip(a, isA: true) }
            if let b = data.bFigures.first { miniFigureChip(b, isA: false) }
        }
    }

    private func miniFigureChip(_ figure: CGImage, isA: Bool) -> some View {
        Image(decorative: figure, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 16, height: 16)
            .clipShape(Circle())
            .overlay(Circle().stroke(isA ? Color.blue : Color.orange, lineWidth: 1.5))
    }

    private func legendBadge(_ letter: String, isA: Bool, size: CGFloat = 40) -> some View {
        Text(letter)
            .font(.system(size: size * 0.6, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(isA ? Color.blue : Color.orange))
            .shadow(radius: 2)
    }

    /// Grab candidate frames around the game's first serve, run the Vision
    /// person detector on each, and keep the frame that shows the most
    /// players (preferring one with both sides represented).
    private func loadLegendData(for game: Game) {
        guard let key = legendKey(for: game),
              legendCache[key] == nil, !legendLoading.contains(key),
              let url = appState.currentAssetURL,
              let first = game.points.first(where: { $0.reviewStatus != .deleted }) else { return }
        legendLoading.insert(key)
        let vertical = appState.serveAxis == .vertical
        let aFirst = appState.sideAIsFirstHalf(for: game)
        let candidates = [first.start + 0.5, (first.start + first.end) / 2, first.start + 2.0]
        Task.detached {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            var best: LegendData?
            for t in candidates {
                let cm = CMTime(seconds: t, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(at: cm, actualTime: nil) else { continue }
                let data = LegendFigureDetector.analyze(frame: image, vertical: vertical, aFirst: aFirst)
                if best == nil || data.boxes.count > (best?.boxes.count ?? 0) { best = data }
                if !data.aFigures.isEmpty && !data.bFigures.isEmpty && data.boxes.count >= 2 {
                    best = data
                    break
                }
            }
            let result = best
            await MainActor.run {
                legendLoading.remove(key)
                if let result { legendCache[key] = result }
            }
        }
    }

    // MARK: - Save for Training

    @ViewBuilder
    private var saveForTrainingButton: some View {
        let isSaving: Bool = {
            if case .saving = appState.trainingPoolStatus { return true }
            return false
        }()

        VStack(spacing: 6) {
            if isSaving, case .saving(let progress) = appState.trainingPoolStatus {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: { appState.saveTrainingClips() }) {
                HStack {
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text(appState.currentVideoInPool ? "Re-save for Training" : "Save for Training")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(appState.games.isEmpty || isSaving)

            if appState.currentVideoInPool {
                Text("This video is already in the training pool")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Point Row

struct PointRow: View {
    let point: GamePoint
    var isSelected: Bool = false
    var playheadTime: TimeInterval = 0
    var score: ServeDetector.PointScore?
    var scoreBefore: ServeDetector.PointScore?
    var chip: ReviewChip = .auto
    var rating: HighlightRating?
    var highlightScore: Double?
    var isTopHighlight: Bool = false
    var gameNumber: Int?
    let onToggleDelete: () -> Void
    var onRate: ((HighlightRating) -> Void)?
    var onFeedback: ((PointFeedbackReason) -> Void)?
    var isBatchSelected: Bool = false
    var isOverlapping: Bool = false
    var winnerIsA: Bool?
    var onOverrideWinner: ((Bool) -> Void)?
    var onStartNewGame: (() -> Void)?
    var onRecalculateScore: (() -> Void)?
    var onSetScore: (() -> Void)?
    let onTap: () -> Void

    /// After-score with the component that just incremented rendered bold in
    /// the winning side's color (A blue / B orange).
    private func scoreAfterText(_ score: ServeDetector.PointScore) -> Text {
        let before = scoreBefore ?? ServeDetector.PointScore(scoreA: 0, scoreB: 0)
        let aWon = score.scoreA > before.scoreA
        let bWon = score.scoreB > before.scoreB
        return Text("\(score.scoreA)")
            .fontWeight(aWon ? .bold : .regular)
            .foregroundColor(aWon ? .blue : .secondary)
        + Text(":").foregroundColor(.secondary)
        + Text("\(score.scoreB)")
            .fontWeight(bWon ? .bold : .regular)
            .foregroundColor(bWon ? .orange : .secondary)
    }

    private var progress: Double {
        guard point.duration > 0 else { return 0 }
        let elapsed = playheadTime - point.start
        return max(0, min(1, elapsed / point.duration))
    }

    private var isPlaying: Bool {
        isSelected && playheadTime >= point.start && playheadTime <= point.end
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(gameNumber.map { "G\($0)#\(point.pointNumber)" } ?? "#\(point.pointNumber)")
                    .font(.caption).bold()
                    .frame(width: gameNumber == nil ? 30 : 44, alignment: .leading)

                if let score = score {
                    // Score transition: "before → after", with the winner's
                    // incremented number bolded in their side's color.
                    HStack(spacing: 2) {
                        Text((scoreBefore ?? ServeDetector.PointScore(scoreA: 0, scoreB: 0)).display)
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        scoreAfterText(score)
                            .font(.caption).monospacedDigit()
                    }
                    .frame(minWidth: 68, alignment: .center)
                    .help("Score before this play → after (winner's number highlighted)")
                }

                Text("\(formatTime(point.start)) – \(formatTime(point.end))")
                    .font(.callout).monospacedDigit()

                Text(String(format: "(%.1fs)", point.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let winnerIsA {
                    Text(winnerIsA ? "A" : "B")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(winnerIsA ? Color.blue : Color.orange)
                        .frame(width: 10)
                        .help(winnerIsA ? "Side A won this play" : "Side B won this play")
                }

                if isOverlapping {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help("Overlaps a neighboring point — delete one or drag the boundaries apart.")
                }

                if let highlightScore {
                    HStack(spacing: 2) {
                        Image(systemName: isTopHighlight ? "star.fill" : "star")
                            .foregroundStyle(isTopHighlight ? Color.yellow : Color.secondary)
                        Text(String(format: "%.2f", highlightScore))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .help(isTopHighlight ? "Highlight score — in the current top-K" : "Highlight score")
                }

                ReviewChipView(chip: chip)

                Spacer()

                if point.reviewStatus != .deleted, let onRate {
                    Button { onRate(.up) } label: {
                        Image(systemName: rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.caption2)
                            .foregroundStyle(rating == .up ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Rate as highlight")

                    // 👎 with a reason: taste feeds the ranker; detection
                    // complaints trigger an automatic fix + tune UI.
                    Menu {
                        Button(rating == .down ? "Clear 👎 rating" : PointFeedbackReason.notHighlight.label) {
                            onRate(.down)
                        }
                        Divider()
                        ForEach(PointFeedbackReason.allCases.filter { $0 != .notHighlight }) { reason in
                            Button(reason.label) { onFeedback?(reason) }
                        }
                    } label: {
                        Image(systemName: rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.caption2)
                            .foregroundStyle(rating == .down ? Color.red : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("What's wrong with this point?")
                }

                Button(action: onToggleDelete) {
                    Image(systemName: point.reviewStatus == .deleted ? "arrow.uturn.backward" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(point.reviewStatus == .deleted ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .help(point.reviewStatus == .deleted ? "Restore point" : "Delete point")
            }

            // Progress bar
            if isSelected {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isPlaying ? Color.accentColor : Color.accentColor.opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.vertical, isSelected ? 2 : 0)
        .opacity(point.reviewStatus == .deleted ? 0.4 : (0.5 + point.confidence * 0.5))
        .strikethrough(point.reviewStatus == .deleted)
        .listRowBackground(
            isBatchSelected
                ? Color.orange.opacity(0.18)
                : (isSelected ? Color.accentColor.opacity(0.12) : nil)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // Right-click verdicts (DESIGN §8.4)
        .contextMenu {
            Button("Play") { onTap() }
            if point.reviewStatus != .deleted, let onRate {
                Button("👍 Highlight") { onRate(.up) }
                Button(PointFeedbackReason.notHighlight.label) { onRate(.down) }
                Menu("What's wrong…") {
                    ForEach(PointFeedbackReason.allCases.filter { $0 != .notHighlight }) { reason in
                        Button(reason.label) { onFeedback?(reason) }
                    }
                }
            }
            if point.reviewStatus != .deleted, let onOverrideWinner {
                Menu("Score wrong — who won this play?") {
                    // Native checkmark on the currently-scored winner, so
                    // correcting is one click on the other row.
                    Toggle("Side A won", isOn: Binding(
                        get: { winnerIsA == true },
                        set: { _ in onOverrideWinner(true) }
                    ))
                    Toggle("Side B won", isOn: Binding(
                        get: { winnerIsA == false },
                        set: { _ in onOverrideWinner(false) }
                    ))
                    if winnerIsA == nil {
                        Divider()
                        Text("Winner not determined yet")
                    }
                }
                Button("Recalculate score from here") { onRecalculateScore?() }
                Button("Set score after this play…") { onSetScore?() }
                Button("Start new game from this play…") { onStartNewGame?() }
            }
            Divider()
            Button(point.reviewStatus == .deleted ? "Restore" : "Delete", action: onToggleDelete)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Review Chip

struct ReviewChipView: View {
    let chip: ReviewChip

    private var color: Color {
        switch chip {
        case .auto: return .gray
        case .confirmed: return .green
        case .edited: return .orange
        case .added: return .blue
        case .deleted: return .red
        }
    }

    var body: some View {
        Text(chip.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - Game Section Header

struct GameSectionHeader: View {
    let game: Game
    var pointScores: [UUID: ServeDetector.PointScore] = [:]

    /// Final score for this game: the score after the last active point.
    private var finalScore: ServeDetector.PointScore? {
        let activePoints = game.points.filter { $0.reviewStatus != .deleted }
        guard let lastPoint = activePoints.last else { return nil }
        return pointScores[lastPoint.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Game \(game.gameNumber)")
                    .font(.callout).bold()

                if let score = finalScore {
                    Text("(\(score.display))")
                        .font(.callout).bold()
                        .foregroundStyle(.secondary)
                }

                Text("— \(game.activePointCount) points")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                validationIcon
            }
            if let message = game.validationMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var validationIcon: some View {
        switch game.validationStatus {
        case .normal:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .tooFew, .tooMany:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        }
    }
}


// MARK: - Legend Figure Detection

/// A court frame plus the players Vision detected in it, split into A/B.
struct LegendData {
    var frame: CGImage
    /// Player bounding boxes in frame pixel coordinates (top-left origin).
    var boxes: [(rect: CGRect, isA: Bool)]
    var aFigures: [CGImage]
    var bFigures: [CGImage]
    var vertical: Bool
    var aFirst: Bool
}

enum LegendFigureDetector {

    /// Runs VNDetectHumanRectanglesRequest and assigns each detected person
    /// to Side A or B by which court half (per the serve axis) they stand in.
    static func analyze(frame: CGImage, vertical: Bool, aFirst: Bool) -> LegendData {
        let w = CGFloat(frame.width)
        let h = CGFloat(frame.height)

        func detect(upperBodyOnly: Bool) -> [VNHumanObservation] {
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = upperBodyOnly
            let handler = VNImageRequestHandler(cgImage: frame, options: [:])
            try? handler.perform([request])
            return (request.results ?? []).filter { $0.confidence > 0.25 }
        }
        var observations = detect(upperBodyOnly: false)
        if observations.isEmpty { observations = detect(upperBodyOnly: true) }

        let rects = observations
            .map { VNImageRectForNormalizedRect($0.boundingBox, Int(w), Int(h)) }
            .map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }
            .filter { $0.height >= h * 0.05 }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(6)

        var boxes: [(rect: CGRect, isA: Bool)] = []
        var aFigures: [CGImage] = []
        var bFigures: [CGImage] = []
        for rect in rects {
            let firstHalf = vertical ? rect.midY < h / 2 : rect.midX < w / 2
            let isA = firstHalf == aFirst
            boxes.append((rect, isA))
            let padded = CGRect(x: rect.minX - rect.width * 0.15,
                                y: rect.minY - rect.height * 0.1,
                                width: rect.width * 1.3,
                                height: rect.height * 1.2)
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let crop = frame.cropping(to: padded) else { continue }
            if isA {
                if aFigures.count < 3 { aFigures.append(crop) }
            } else {
                if bFigures.count < 3 { bFigures.append(crop) }
            }
        }
        return LegendData(frame: frame, boxes: boxes, aFigures: aFigures,
                          bFigures: bFigures, vertical: vertical, aFirst: aFirst)
    }
}
