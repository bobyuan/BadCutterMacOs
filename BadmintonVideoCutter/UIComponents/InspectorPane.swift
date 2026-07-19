import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case points = "Points"
    case export = "Export"
    case models = "Models"

    var id: String { rawValue }
}

/// Right pane of the Studio layout: Points (review), Export (policies +
/// summary), Models (training pool + calibration).
struct InspectorPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: TimelineController
    @Binding var showCalibration: Bool
    @State private var tab: InspectorTab = .points

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .points:
                pointsPanel
            case .export:
                ExportPanel(appState: appState)
            case .models:
                ModelsPanel(appState: appState, showCalibration: $showCalibration)
            }
        }
    }

    // MARK: - Points

    private var pointsPanel: some View {
        PointListView(
            appState: appState,
            selectedPointID: controller.selectedPointID,
            playheadTime: controller.playheadTime
        ) { point in
            controller.preview(point)
        }
        .onAppear {
            // Trigger serve detection if games exist but scores haven't been computed yet
            if !appState.games.isEmpty && appState.pointScores.isEmpty {
                appState.detectServesAndScores()
            }
        }
    }
}

// MARK: - Export Panel

struct ExportPanel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if appState.currentAssetURL == nil {
                    emptyState("Import and analyze a video first")
                } else if appState.segments.isEmpty {
                    emptyState("Analyze this video to export")
                } else {
                    settings
                    exportButton
                    Divider()
                    if let stats = appState.removalStatistics {
                        summary(stats: stats)
                    }
                }
            }
            .padding(14)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Mode") {
                Picker("Mode", selection: $appState.exportConfig.mode) {
                    ForEach(ExportMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.vertical, 2)
            }

            GroupBox("Transition") {
                Picker("Style", selection: $appState.exportConfig.transition) {
                    ForEach(TransitionStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.vertical, 2)
            }

            GroupBox("Format") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Match source format", isOn: $appState.exportConfig.matchSourceFormat)
                    if let meta = appState.videoMetadata {
                        Text("Source: \(meta.codec) \(meta.formattedResolution)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var exportButton: some View {
        Button(action: { appState.exportRallyOnly() }) {
            HStack {
                if appState.isExporting {
                    ProgressView().controlSize(.small)
                }
                Text(appState.isExporting ? "Exporting…" : "Export Video")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(appState.isExporting || appState.segments.isEmpty)
    }

    // MARK: Summary (absorbs the old Rm Stats tab essentials)

    private func summary(stats: RemovalStatistics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)

            proportionBar(stats: stats)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Input").foregroundStyle(.secondary)
                    Text(formatDuration(stats.originalDuration)).bold()
                }
                GridRow {
                    Text("Output").foregroundStyle(.secondary)
                    Text(formatDuration(stats.keptDuration)).bold().foregroundStyle(.green)
                }
                GridRow {
                    Text("Removed").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%% (%@)", stats.trimPercent, formatDuration(stats.removedDuration)))
                        .bold()
                        .foregroundStyle(.red)
                }
                GridRow {
                    Text("Points").foregroundStyle(.secondary)
                    Text("\(stats.rallyCount)").bold()
                }
                GridRow {
                    Text("Gaps removed").foregroundStyle(.secondary)
                    Text("\(stats.trimCount)").bold()
                }
                if let meta = appState.videoMetadata {
                    GridRow {
                        Text("Est. size").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(Double(meta.fileSize) * (stats.keptPercent / 100)),
                            countStyle: .file
                        )).bold()
                    }
                }
            }
            .font(.callout)

            let flagged = appState.trimSegments.filter { $0.reviewStatus == .flagged }.count
            if flagged > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("\(flagged) flagged trim(s) will be kept in the output.")
                        .font(.caption)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.yellow.opacity(0.1)))
            }
        }
    }

    private func proportionBar(stats: RemovalStatistics) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                Rectangle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(stats.keptPercent / 100))
                Rectangle()
                    .fill(Color.red.opacity(0.5))
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            Text(String(format: "keep %.0f%%", stats.keptPercent))
                .font(.caption2).bold()
                .foregroundStyle(.white)
        )
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Models Panel

struct ModelsPanel: View {
    @ObservedObject var appState: AppState
    @Binding var showCalibration: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                shuttleSection
                Divider()
                hitDetectionSection
            }
            .padding(14)
        }
    }

    // MARK: Shuttlecock model + calibration

    private var shuttleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shuttlecock Tracking")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.hasShuttlecockModel ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(appState.hasShuttlecockModel ? "TrackNetV3 model active" : "ML model not found — using heuristic")
                    .font(.caption)
            }

            Button {
                if appState.calibrationFrames.isEmpty {
                    appState.generateCalibrationFrames()
                }
                showCalibration = true
            } label: {
                HStack {
                    Image(systemName: "target")
                    Text("Calibrate Shuttlecock…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.featureFrames.isEmpty)

            if appState.featureFrames.isEmpty {
                Text("Analyze a video first to calibrate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Audio hit detection (from the old Videos tab)

    private var hitDetectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Hit Detection")
                .font(.headline)

            hitModelStatusRow
            trainingPoolInfoView
            trainingActionButtons
        }
    }

    @ViewBuilder
    private var hitModelStatusRow: some View {
        switch appState.hitModelStatus {
        case .notTrained:
            HStack(spacing: 6) {
                Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Text("Sound model: not trained")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .training(let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .trained(let accuracy, let clipCount):
            HStack(spacing: 6) {
                Toggle("", isOn: $appState.useHitModel)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Circle().fill(Color.green).frame(width: 8, height: 8)
                if clipCount > 0 {
                    Text(String(format: "Trained (%d clips, %.0f%%)", clipCount, accuracy * 100))
                        .font(.caption)
                } else {
                    Text("Trained (previous session)")
                        .font(.caption)
                }
            }
        case .failed(let error):
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Failed: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var trainingPoolInfoView: some View {
        let manifest = appState.trainingPoolManifest
        if manifest.videos.isEmpty {
            Text("No training data yet. Review points, then use “Save for Training” in the Points panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(manifest.videos.count) video(s): \(manifest.totalRallyClips) rally + \(manifest.totalBackgroundClips) background clips")
                    .font(.caption)
                ForEach(manifest.videos) { entry in
                    HStack(spacing: 4) {
                        Text(entry.videoFileName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.rallyClipCount)r / \(entry.backgroundClipCount)b")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trainingActionButtons: some View {
        let isTraining: Bool = {
            if case .training = appState.hitModelStatus { return true }
            return false
        }()
        let hasModel: Bool = {
            if case .trained = appState.hitModelStatus { return true }
            return false
        }()
        let hasPoolData = !appState.trainingPoolManifest.videos.isEmpty

        HStack(spacing: 8) {
            Button("Train Model") {
                appState.trainFromPool()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasPoolData || isTraining)

            if hasModel {
                Button("Delete Model") {
                    appState.deleteHitModel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTraining)
            }

            if hasPoolData {
                Button("Clear Data") {
                    appState.clearTrainingPool()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTraining)
            }
        }

        if hasModel {
            Text("Re-analyze to apply the sound model. Uncheck to skip it.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
