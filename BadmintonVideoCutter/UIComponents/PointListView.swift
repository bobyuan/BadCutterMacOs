import SwiftUI

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
                                    serveSide: appState.effectiveServeSide(for: point.id),
                                    serveLabelA: appState.serveMenuLabels(for: game).left,
                                    serveLabelB: appState.serveMenuLabels(for: game).right,
                                    onOverrideServe: { side in
                                        appState.overrideServeSide(pointID: point.id, side: side)
                                    },
                                    onRecalculateScore: {
                                        appState.recalculateScores(fromPointID: point.id)
                                    },
                                    onTap: {
                                        handleTap(on: point)
                                    }
                                )
                            }
                        } header: {
                            GameSectionHeader(game: game, pointScores: appState.pointScores)
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
                    serveSide: appState.effectiveServeSide(for: entry.point.id),
                    serveLabelA: appState.serveMenuLabels(for: entry.game).left,
                    serveLabelB: appState.serveMenuLabels(for: entry.game).right,
                    onOverrideServe: { side in
                        appState.overrideServeSide(pointID: entry.point.id, side: side)
                    },
                    onRecalculateScore: {
                        appState.recalculateScores(fromPointID: entry.point.id)
                    },
                    onTap: {
                        handleTap(on: entry.point)
                    }
                )
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
    var serveSide: ServeDetector.ServeSide?
    var serveLabelA = "Side A"
    var serveLabelB = "Side B"
    var onOverrideServe: ((ServeDetector.ServeSide) -> Void)?
    var onRecalculateScore: (() -> Void)?
    let onTap: () -> Void

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
                    Text(score.display)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .center)
                }

                Text("\(formatTime(point.start)) – \(formatTime(point.end))")
                    .font(.callout).monospacedDigit()

                Text(String(format: "(%.1fs)", point.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
            if point.reviewStatus != .deleted, let onOverrideServe {
                Menu("Score wrong — who serves?") {
                    Button(serveSide == .left ? "✓ \(serveLabelA) serves" : "\(serveLabelA) serves") { onOverrideServe(.left) }
                    Button(serveSide == .right ? "✓ \(serveLabelB) serves" : "\(serveLabelB) serves") { onOverrideServe(.right) }
                }
                Button("Recalculate score from here") { onRecalculateScore?() }
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
