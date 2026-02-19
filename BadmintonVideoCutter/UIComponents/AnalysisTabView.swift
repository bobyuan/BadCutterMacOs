import SwiftUI

struct AnalysisTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HSplitView {
            // Left: Controls
            VStack(alignment: .leading, spacing: 20) {
                Text("Analysis")
                    .font(.title2).bold()

                if appState.currentAssetURL == nil {
                    noVideoView
                } else {
                    controlsView
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 320)

            // Right: Progress + results
            VStack(spacing: 16) {
                if appState.isAnalyzing {
                    progressView
                } else if !appState.segments.isEmpty {
                    resultsView
                } else {
                    placeholderView
                }
            }
            .padding(24)
            .frame(minWidth: 400)
        }
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Sensitivity Preset") {
                Picker("Sensitivity", selection: $appState.sensitivity) {
                    ForEach(SensitivityPreset.allCases) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                Text(sensitivityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Weights") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Motion")
                        Spacer()
                        Text(String(format: "%.0f%%", appState.sensitivity.motionWeight * 100))
                            .foregroundStyle(.blue)
                    }
                    HStack {
                        Text("Audio")
                        Spacer()
                        Text(String(format: "%.0f%%", appState.sensitivity.audioWeight * 100))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .padding(.vertical, 4)
            }

            Button(action: { appState.analyzeCurrentVideo() }) {
                HStack {
                    if appState.isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appState.isAnalyzing ? "Analyzing..." : "Analyze Video")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isAnalyzing)

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var noVideoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Import a video first")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sensitivityDescription: String {
        switch appState.sensitivity {
        case .conservative: return "Keeps more content. Better for short rallies."
        case .balanced: return "Good balance between precision and recall."
        case .aggressive: return "Removes more between-points. Best for long rallies."
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        let progress = appState.analysisProgress

        return VStack(spacing: 20) {
            Text("Analyzing Video")
                .font(.title3).bold()

            // Overall progress
            VStack(spacing: 6) {
                HStack {
                    Text("Overall")
                        .font(.callout).bold()
                    Spacer()
                    Text(String(format: "%.0f%%", progress.overallProgress * 100))
                        .font(.title2).bold()
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
                progressBar(value: progress.overallProgress, color: .accentColor)
            }

            // Per-track progress (only during extraction)
            if progress.stage == .extracting {
                GroupBox {
                    VStack(spacing: 12) {
                        // Video frames bar
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "film")
                                    .foregroundStyle(.blue)
                                Text("Video Frames")
                                    .font(.callout)
                                Spacer()
                                Text(String(format: "%.0f%%", progress.videoProgress * 100))
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            progressBar(value: progress.videoProgress, color: .blue)
                        }

                        // Audio analysis bar
                        VStack(spacing: 4) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.orange)
                                Text("Audio Analysis")
                                    .font(.callout)
                                Spacer()
                                Text(String(format: "%.0f%%", progress.audioProgress * 100))
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            progressBar(value: progress.audioProgress, color: .orange)
                        }
                    }
                    .padding(4)
                }
            }

            // Finalizing indicator
            if progress.stage == .finalizing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scoring and classifying segments...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Elapsed time
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("Elapsed: \(formatElapsed(progress.elapsedSeconds))")
                    .monospacedDigit()
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private func progressBar(value: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(value)))
                    .animation(.linear(duration: 0.3), value: value)
            }
        }
        .frame(height: 10)
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Analysis Results")
                    .font(.title3).bold()
                Spacer()
                if appState.analysisProgress.elapsedSeconds > 0 {
                    Text("Completed in \(formatElapsed(appState.analysisProgress.elapsedSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let rallies = appState.segments.filter { $0.label == .rally }
            let betweens = appState.segments.filter { $0.label == .betweenPoints }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Games Detected").foregroundStyle(.secondary)
                        Text("\(appState.games.count)").bold()
                    }
                    ForEach(appState.games) { game in
                        GridRow {
                            Text("Game \(game.gameNumber)").foregroundStyle(.secondary)
                            Text("\(game.activePointCount) points").bold()
                        }
                    }
                    GridRow {
                        Text("Point Time").foregroundStyle(.secondary)
                        Text(formatDuration(rallies.reduce(0) { $0 + $1.duration })).bold()
                    }
                    GridRow {
                        Text("Trim Time").foregroundStyle(.secondary)
                        Text(formatDuration(betweens.reduce(0) { $0 + $1.duration })).bold()
                    }
                }
                .padding(8)
            }

            miniTimeline

            Spacer()
        }
    }

    private var miniTimeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Segment Overview")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let totalDuration = appState.videoMetadata?.duration ?? appState.segments.last?.end ?? 1
                HStack(spacing: 1) {
                    ForEach(appState.segments) { seg in
                        let fraction = seg.duration / totalDuration
                        Rectangle()
                            .fill(seg.label == .rally ? Color.green.opacity(0.8) : Color.red.opacity(0.5))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(.green.opacity(0.8)).frame(width: 8, height: 8)
                    Text("Rally").font(.caption2)
                }
                HStack(spacing: 4) {
                    Circle().fill(.red.opacity(0.5)).frame(width: 8, height: 8)
                    Text("Between Points").font(.caption2)
                }
            }
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Run analysis to detect rally segments")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        }
        return String(format: "%ds", secs)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
