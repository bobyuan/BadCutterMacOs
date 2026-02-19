import SwiftUI

struct PointListView: View {
    @ObservedObject var appState: AppState
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
                                PointRow(point: point, onToggleDelete: {
                                    let newStatus: PointReviewStatus = point.reviewStatus == .deleted ? .unreviewed : .deleted
                                    appState.setPointReviewStatus(pointID: point.id, status: newStatus)
                                }, onTap: {
                                    onSelectPoint?(point)
                                })
                            }
                        } header: {
                            GameSectionHeader(game: game)
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
        }
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
    let onToggleDelete: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("#\(point.pointNumber)")
                .font(.caption).bold()
                .frame(width: 30, alignment: .leading)

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
        .opacity(point.reviewStatus == .deleted ? 0.4 : (0.5 + point.confidence * 0.5))
        .strikethrough(point.reviewStatus == .deleted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Game \(game.gameNumber) — \(game.activePointCount) points")
                    .font(.callout).bold()
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
