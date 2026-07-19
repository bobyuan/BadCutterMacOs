import SwiftUI

struct PointListView: View {
    @ObservedObject var appState: AppState
    var selectedPointID: UUID?
    var playheadTime: TimeInterval = 0
    var onSelectPoint: ((GamePoint) -> Void)?

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
                Text("\(totalPoints) points in \(gameCount) game\(gameCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                List {
                    ForEach(appState.games) { game in
                        Section {
                            ForEach(game.points) { point in
                                PointRow(
                                    point: point,
                                    isSelected: point.id == selectedPointID,
                                    playheadTime: playheadTime,
                                    score: appState.pointScores[point.id],
                                    onToggleDelete: {
                                        let newStatus: PointReviewStatus = point.reviewStatus == .deleted ? .unreviewed : .deleted
                                        appState.setPointReviewStatus(pointID: point.id, status: newStatus)
                                    },
                                    onTap: {
                                        onSelectPoint?(point)
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

                saveForTrainingButton
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
    let onToggleDelete: () -> Void
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
                Text("#\(point.pointNumber)")
                    .font(.caption).bold()
                    .frame(width: 30, alignment: .leading)

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

                Spacer()

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
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
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
