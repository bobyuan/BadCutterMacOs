import SwiftUI

struct RemovalStatsTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let stats = appState.removalStatistics {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Removal Statistics")
                        .font(.title2).bold()

                    // Before/After cards
                    HStack(spacing: 16) {
                        statCard(title: "Original", duration: stats.originalDuration, icon: "film", color: .blue)
                        statCard(title: "After Trim", duration: stats.keptDuration, icon: "film.fill", color: .green)
                        statCard(title: "Removed", duration: stats.removedDuration, icon: "scissors", color: .red)
                    }

                    // Visual proportion bar
                    proportionBar(stats: stats)

                    // Summary numbers
                    GroupBox("Summary") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            GridRow {
                                Text("Points Detected").foregroundStyle(.secondary)
                                Text("\(stats.rallyCount)").bold()
                            }
                            GridRow {
                                Text("Gaps Removed").foregroundStyle(.secondary)
                                Text("\(stats.trimCount)").bold()
                            }
                            GridRow {
                                Text("Kept").foregroundStyle(.secondary)
                                Text(String(format: "%.1f%%", stats.keptPercent)).bold().foregroundStyle(.green)
                            }
                            GridRow {
                                Text("Removed").foregroundStyle(.secondary)
                                Text(String(format: "%.1f%%", stats.trimPercent)).bold().foregroundStyle(.red)
                            }
                        }
                        .padding(8)
                    }

                    // Duration distributions
                    HStack(alignment: .top, spacing: 16) {
                        distributionChart(
                            title: "Point Durations",
                            durations: stats.rallyDurations,
                            color: .green
                        )
                        distributionChart(
                            title: "Gap Durations",
                            durations: stats.trimDurations,
                            color: .red
                        )
                    }

                    // Per-game points table
                    if !appState.games.isEmpty {
                        gamePointsTable
                    }
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "chart.bar")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Run analysis to see removal statistics")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Stat Card

    private func statCard(title: String, duration: TimeInterval, icon: String, color: Color) -> some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatDuration(duration))
                    .font(.title2).bold()
            }
            .frame(maxWidth: .infinity)
            .padding(8)
        }
    }

    // MARK: - Proportion Bar

    private func proportionBar(stats: RemovalStatistics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kept vs Removed")
                .font(.caption).foregroundStyle(.secondary)

            GeometryReader { geo in
                let keptWidth = geo.size.width * CGFloat(stats.keptPercent / 100)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: max(1, keptWidth))
                    Rectangle()
                        .fill(Color.red.opacity(0.5))
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(.green.opacity(0.7)).frame(width: 8, height: 8)
                    Text(String(format: "Kept %.1f%%", stats.keptPercent)).font(.caption2)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(.red.opacity(0.5)).frame(width: 8, height: 8)
                    Text(String(format: "Removed %.1f%%", stats.trimPercent)).font(.caption2)
                }
            }
        }
    }

    // MARK: - Distribution Chart

    private func distributionChart(title: String, durations: [TimeInterval], color: Color) -> some View {
        GroupBox(title) {
            if durations.isEmpty {
                Text("No data").foregroundStyle(.secondary).font(.caption)
            } else {
                let buckets = bucketize(durations)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(buckets, id: \.label) { bucket in
                        HStack(spacing: 8) {
                            Text(bucket.label)
                                .font(.caption2).monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                            GeometryReader { geo in
                                let maxCount = buckets.map(\.count).max() ?? 1
                                let fraction = CGFloat(bucket.count) / CGFloat(maxCount)
                                Rectangle()
                                    .fill(color.opacity(0.6))
                                    .frame(width: max(2, geo.size.width * fraction))
                            }
                            .frame(height: 14)
                            Text("\(bucket.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private struct Bucket: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    private func bucketize(_ durations: [TimeInterval]) -> [Bucket] {
        let ranges: [(String, ClosedRange<TimeInterval>)] = [
            ("0-5s", 0...5),
            ("5-15s", 5...15),
            ("15-30s", 15...30),
            ("30-60s", 30...60),
            ("60s+", 60...3600)
        ]

        return ranges.compactMap { label, range in
            let count = durations.filter { range.contains($0) }.count
            return count > 0 ? Bucket(label: label, count: count) : nil
        }
    }

    // MARK: - Game Points Table

    private var gamePointsTable: some View {
        ForEach(appState.games) { game in
            GroupBox("Game \(game.gameNumber) — \(game.activePointCount) points") {
                VStack(spacing: 0) {
                    HStack {
                        Text("#").frame(width: 30)
                        Text("Start").frame(width: 60)
                        Text("End").frame(width: 60)
                        Text("Duration").frame(width: 70)
                        Text("Status").frame(width: 80)
                        Spacer()
                    }
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    Divider()

                    ForEach(game.points) { point in
                        HStack {
                            Text("\(point.pointNumber)").frame(width: 30)
                            Text(formatTime(point.start)).frame(width: 60)
                            Text(formatTime(point.end)).frame(width: 60)
                            Text(String(format: "%.1fs", point.duration)).frame(width: 70)
                            Text(point.reviewStatus.rawValue)
                                .frame(width: 80)
                                .foregroundStyle(pointStatusColor(point.reviewStatus))
                            Spacer()
                        }
                        .font(.caption).monospacedDigit()
                        .opacity(point.reviewStatus == .deleted ? 0.4 : 1.0)
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
                .padding(4)
            }
        }
    }

    private func pointStatusColor(_ status: PointReviewStatus) -> Color {
        switch status {
        case .confirmed: return .green
        case .deleted: return .red
        case .unreviewed: return .secondary
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
