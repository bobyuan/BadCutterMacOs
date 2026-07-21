import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case points = "Points"
    case export = "Export"
    case models = "Models"
    case history = "History"

    var id: String { rawValue }
}

/// Right pane of the Studio layout: Points (review), Export (policies +
/// summary), Models (training pool + calibration).
struct InspectorPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: TimelineController
    @Binding var showCalibration: Bool
    @State private var tab: InspectorTab = .points
    /// Play clicked while split mode was active — awaiting exit confirmation.
    @State private var splitExitCandidate: GamePoint?

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
            case .history:
                HistoryPanel(appState: appState)
            }
        }
    }

    // MARK: - Points

    private var pointsPanel: some View {
        PointListView(
            appState: appState,
            selectedPointID: controller.selectedPointID,
            playheadTime: controller.playheadTime,
            onSelectPoint: { point in
                if controller.splitMode {
                    splitExitCandidate = point
                } else {
                    controller.preview(point)
                }
            },
            onFeedback: { point, reason in
                guard let outcome = appState.applyFeedback(pointID: point.id, reason: reason) else { return }
                if let focusID = outcome.focusPointID, let focusPoint = appState.point(withID: focusID) {
                    let duration = appState.videoMetadata?.duration
                        ?? appState.segments.last?.end
                        ?? focusPoint.end + 10
                    controller.beginTuning(
                        point: focusPoint,
                        ghostStart: outcome.ghostStart,
                        ghostEnd: outcome.ghostEnd,
                        videoDuration: duration
                    )
                    // Auto-audition the changed boundary (DESIGN §8.2) so the
                    // fix can be judged without another click.
                    if outcome.autoAdjusted {
                        if outcome.ghostEnd != nil || outcome.ghostStart == nil {
                            controller.playWindow(from: focusPoint.end - 1.5, to: focusPoint.end + 1.5)
                        } else {
                            controller.playWindow(from: focusPoint.start - 1.5, to: focusPoint.start + 1.5)
                        }
                    }
                } else {
                    controller.endTuning()
                }
            }
        )
        .onAppear {
            // Trigger serve detection if games exist but scores haven't been computed yet
            if !appState.games.isEmpty && appState.pointScores.isEmpty {
                appState.detectServesAndScores()
            }
        }
        .alert(
            "Exit split mode?",
            isPresented: Binding(
                get: { splitExitCandidate != nil },
                set: { if !$0 { splitExitCandidate = nil } }
            )
        ) {
            Button("Exit and switch play") {
                controller.splitMode = false
                if let point = splitExitCandidate {
                    controller.preview(point)
                }
                splitExitCandidate = nil
                appState.statusMessage = "Split canceled."
            }
            Button("Stay in split mode", role: .cancel) {
                splitExitCandidate = nil
            }
        } message: {
            Text("The cut isn't done yet — switching plays will cancel it.")
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
                    if !appState.exportOutputs.isEmpty {
                        results
                    }
                    Divider()
                    reelEstimates
                    if let stats = appState.removalStatistics {
                        summary(stats: stats)
                    }
                }
            }
            .padding(14)
        }
    }

    private enum HighlightMode: String, CaseIterable, Identifiable {
        case percent = "Top %"
        case minutes = "Minutes"
        case threshold = "Score ≥"

        var id: String { rawValue }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Reels") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Scoring reel — every active point", isOn: reelBinding(.scoring))
                    Toggle("Highlight reel — best points", isOn: reelBinding(.highlights))
                    if appState.exportPlan.reels.contains(.highlights) {
                        highlightSelectionControls
                    }
                }
                .padding(.vertical, 2)
            }

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Individual clip per point", isOn: $appState.exportPlan.individualClips)
                    Toggle("Score overlay on scoring reel", isOn: $appState.exportPlan.scoreOverlay)
                    Picker("Transition", selection: $appState.exportPlan.transition) {
                        ForEach(TransitionStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Match source format", isOn: $appState.exportPlan.matchSourceFormat)
                    if let meta = appState.videoMetadata {
                        Text("Source: \(meta.codec) \(meta.formattedResolution). Keeps the codec (cuts snap to keyframes); off re-encodes at highest quality.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if appState.exportPlan.scoreOverlay || appState.exportPlan.transition == .crossfade {
                        Text("Overlay/crossfade reels re-encode regardless of format setting.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func reelBinding(_ reel: ExportPlan.Reel) -> Binding<Bool> {
        Binding(
            get: { appState.exportPlan.reels.contains(reel) },
            set: { on in
                if on {
                    appState.exportPlan.reels.insert(reel)
                } else {
                    appState.exportPlan.reels.remove(reel)
                }
            }
        )
    }

    private var highlightMode: Binding<HighlightMode> {
        Binding(
            get: {
                switch appState.exportPlan.highlightSelection {
                case .topPercent: return .percent
                case .topMinutes: return .minutes
                case .threshold: return .threshold
                }
            },
            set: { mode in
                switch mode {
                case .percent: appState.exportPlan.highlightSelection = .topPercent(20)
                case .minutes: appState.exportPlan.highlightSelection = .topMinutes(3)
                case .threshold: appState.exportPlan.highlightSelection = .threshold(0.7)
                }
            }
        )
    }

    @ViewBuilder
    private var highlightSelectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: highlightMode) {
                ForEach(HighlightMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch appState.exportPlan.highlightSelection {
            case .topPercent(let percent):
                selectionSlider(value: percent, range: 5...100, step: 5, format: "%.0f%%") {
                    appState.exportPlan.highlightSelection = .topPercent($0)
                }
            case .topMinutes(let minutes):
                selectionSlider(value: minutes, range: 0.5...10, step: 0.5, format: "%.1f min") {
                    appState.exportPlan.highlightSelection = .topMinutes($0)
                }
            case .threshold(let score):
                selectionSlider(value: score, range: 0...1, step: 0.05, format: "≥ %.2f") {
                    appState.exportPlan.highlightSelection = .threshold($0)
                }
            }

            let picked = appState.highlightReelPoints
            let total = picked.reduce(0) { $0 + $1.duration }
            Text("→ \(picked.count) point\(picked.count == 1 ? "" : "s") · \(formatDuration(total))")
                .font(.caption)
                .foregroundStyle(picked.isEmpty ? .orange : .secondary)
        }
        .padding(.leading, 18)
    }

    private func selectionSlider(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                step: step
            )
            Text(String(format: format, value))
                .font(.caption).monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var exportButton: some View {
        Button(action: { appState.runExport() }) {
            HStack {
                if appState.isExporting {
                    ProgressView().controlSize(.small)
                }
                Text(appState.isExporting ? "Exporting…" : "Export")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            appState.isExporting
                || appState.segments.isEmpty
                || (appState.exportPlan.reels.isEmpty && !appState.exportPlan.individualClips)
        )
    }

    // MARK: Per-reel estimates + results

    /// Bytes per second of the source — used for size estimates.
    private var sourceBytesPerSecond: Double? {
        guard let meta = appState.videoMetadata, meta.duration > 0, meta.fileSize > 0 else { return nil }
        return Double(meta.fileSize) / meta.duration
    }

    @ViewBuilder
    private var reelEstimates: some View {
        let scoringDuration = appState.effectiveKeptSegments.reduce(0) { $0 + $1.duration }
        let highlightDuration = appState.highlightReelPoints.reduce(0) { $0 + $1.duration }

        VStack(alignment: .leading, spacing: 6) {
            Text("Will export")
                .font(.headline)
            if appState.exportPlan.reels.contains(.scoring) {
                estimateRow(label: "Scoring reel", duration: scoringDuration)
            }
            if appState.exportPlan.reels.contains(.highlights) {
                estimateRow(label: "Highlight reel", duration: highlightDuration)
            }
            if appState.exportPlan.individualClips {
                let count = appState.exportPlan.reels.contains(.scoring)
                    ? appState.activePoints.count
                    : appState.highlightReelPoints.count
                Text("\(count) individual clips → <video>.clips/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.exportPlan.reels.isEmpty && !appState.exportPlan.individualClips {
                Text("Nothing selected.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func estimateRow(label: String, duration: TimeInterval) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(formatDuration(duration))
                .font(.callout).monospacedDigit().bold()
            if let bps = sourceBytesPerSecond {
                Text("~" + ByteCountFormatter.string(fromByteCount: Int64(duration * bps), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exported")
                .font(.headline)
            ForEach(appState.exportOutputs.filter { !$0.label.hasPrefix("Clip") }) { output in
                resultRow(output)
            }
            let clips = appState.exportOutputs.filter { $0.label.hasPrefix("Clip") }
            if !clips.isEmpty {
                HStack {
                    Text("\(clips.count) clips").font(.callout)
                    Spacer()
                    Button("Show in Finder") {
                        if let first = clips.first {
                            NSWorkspace.shared.activateFileViewerSelecting([first.url])
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.green.opacity(0.08)))
    }

    private func resultRow(_ output: ExportOutput) -> some View {
        HStack {
            Text(output.label).font(.callout)
            Spacer()
            Text(formatDuration(output.duration))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: output.fileSize, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([output.url])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
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
                Divider()
                rankerSection
                Divider()
                feedbackSignalsSection
            }
            .padding(14)
        }
        .onAppear { appState.refreshRankerRatingCount(thenAutoTrain: true) }
    }

    // MARK: Highlight ranker (learned from 👍/👎 ratings)

    private var rankerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlight Ranker")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.rankerRegistry.currentVersion() != nil ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(appState.rankerRegistry.currentVersion() != nil
                     ? "Personal ranker active — replaces the built-in weights"
                     : "Using built-in heuristic weights")
                    .font(.caption)
            }

            Text("\(appState.rankerRatingCount) rating\(appState.rankerRatingCount == 1 ? "" : "s") collected (need \(HighlightRanker.minimumRatings)). Trains automatically as ratings accumulate; gate keeps a worse model from taking over.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(appState.isTrainingRanker ? "Training…" : "Train Ranker") {
                    appState.trainHighlightRanker()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.rankerRatingCount < HighlightRanker.minimumRatings || appState.isTrainingRanker)

                if !appState.rankerVersions.isEmpty {
                    Button("Delete Ranker") {
                        appState.deleteRanker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isTrainingRanker)
                }
            }

            if !appState.rankerVersions.isEmpty {
                ModelVersionListView(
                    versions: appState.rankerVersions,
                    metricLabel: { meta in
                        String(format: "conc %.2f", meta.trainingAccuracy)
                    },
                    onPromote: { appState.promoteRanker(version: $0) }
                )
            }
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
            if !appState.hitModelVersions.isEmpty {
                modelVersionList
            }
        }
    }

    /// Registry versions with shadow-eval metrics; one-click promote/revert.
    private var modelVersionList: some View {
        ModelVersionListView(
            versions: appState.hitModelVersions,
            metricLabel: { meta in
                if let eval = meta.shadowEval, eval.sessionCount > 0 {
                    return String(format: "F1 %.2f · ±%.1fs", eval.f1, eval.boundaryMAE)
                }
                return meta.trainingAccuracy > 0 ? String(format: "%.0f%%", meta.trainingAccuracy * 100) : nil
            },
            onPromote: { appState.promoteHitModel(version: $0) }
        )
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

    // MARK: Feedback signals (DESIGN §8.6)

    @ViewBuilder
    private var feedbackSignalsSection: some View {
        let counts = appState.feedbackReasonCounts()
        VStack(alignment: .leading, spacing: 8) {
            Text("Feedback Signals")
                .font(.headline)
            if counts.isEmpty {
                Text("No detection complaints on this video yet. 👎 reasons collect here and will drive per-venue tuning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(counts, id: \.reason) { item in
                    HStack(spacing: 6) {
                        Text("\(item.count)×")
                            .font(.caption).bold().monospacedDigit()
                        Text(item.reason.label)
                            .font(.caption)
                        Spacer()
                    }
                }
                if let top = counts.first, top.count >= 3 {
                    Text(hint(for: top.reason, count: top.count))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func hint(for reason: PointFeedbackReason, count: Int) -> String {
        switch reason {
        case .startsTooEarly:
            return "\(count)× — pre-roll may be too generous for this venue (venue profiles, DESIGN §3.6)."
        case .endsTooLate:
            return "\(count)× — post-roll may be too generous for this venue."
        case .startsTooLate:
            return "\(count)× — pre-roll may be too tight for this venue."
        case .endsTooEarly:
            return "\(count)× — post-roll may be too tight for this venue."
        case .missedPointBefore:
            return "\(count)× — detection threshold may be too strict; consider a more aggressive preset."
        case .shouldSplit:
            return "\(count)× — split sensitivity may be too low for this venue."
        case .notAPoint:
            return "\(count)× — detection threshold may be too loose; consider a more conservative preset."
        case .notHighlight:
            return ""
        }
    }

    // MARK: Shared model-version list

    struct ModelVersionListView: View {
        var versions: [ModelVersionMetadata]
        var metricLabel: (ModelVersionMetadata) -> String?
        var onPromote: (Int) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model Versions")
                    .font(.subheadline).bold()
                ForEach(versions.reversed()) { meta in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(meta.versionLabel)
                                .font(.caption).bold().monospacedDigit()
                            if meta.promoted {
                                Text("current")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Capsule().fill(.green.opacity(0.18)))
                                    .foregroundStyle(.green)
                            }
                            Text(meta.trainedAt, format: .dateTime.month().day())
                                .font(.caption2).foregroundStyle(.secondary)
                            if let metric = metricLabel(meta) {
                                Text(metric)
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            if !meta.promoted {
                                Button(versions.last?.id == meta.id ? "Promote" : "Revert to") {
                                    onPromote(meta.version)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        if let gate = meta.gateDecision, !gate.promote, !meta.promoted {
                            Text("Held: \(gate.reason)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
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

// MARK: - History Panel

/// Analysis versions + the full adjustment audit trail, straight from the
/// ledger. Makes "re-analysis never erases anything" visible.
struct HistoryPanel: View {
    @ObservedObject var appState: AppState
    /// Per-run point labels, computed lazily per card render.
    @State private var labelsByRun: [Int: [UUID: String]] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if appState.runSummaries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No analysis yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Every analysis and every manual adjustment will be recorded here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(appState.runSummaries.reversed()) { summary in
                        runCard(summary)
                    }
                    footer
                }
            }
            .padding(12)
        }
    }

    private func runCard(_ summary: SessionStore.RunSummary) -> some View {
        let isCurrent = summary.run == appState.currentAnalysisRun
        let entries = appState.historyEntries(forRun: summary.run)
        let corrections = entries.filter { $0.event.isCorrection }.count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary.label)
                    .font(.callout).bold()
                if isCurrent {
                    Text("current")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
                Text(summary.savedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(summary.pointCount) pts")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !isCurrent {
                    Button("Switch back") { appState.switchToRun(summary.run) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            if corrections > 0 || !entries.isEmpty {
                Text(activitySummary(entries: entries))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(entries.prefix(30).enumerated()), id: \.offset) { _, entry in
                historyRow(entry, run: summary.run)
            }
            if entries.count > 30 {
                Text("… \(entries.count - 30) earlier events")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent ? Color.green.opacity(0.06) : Color.gray.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isCurrent ? Color.green.opacity(0.35) : Color.gray.opacity(0.2)))
        .onAppear {
            if labelsByRun[summary.run] == nil {
                labelsByRun[summary.run] = appState.pointLabels(forRun: summary.run)
            }
        }
    }

    private func activitySummary(entries: [LedgerEntry]) -> String {
        var deleted = 0, added = 0, moved = 0, rated = 0, exported = 0
        for entry in entries {
            switch entry.event {
            case .pointDeleted: deleted += 1
            case .pointAdded: added += 1
            case .boundaryChanged: moved += 1
            case .highlightRated: rated += 1
            case .exported: exported += 1
            default: break
            }
        }
        var parts: [String] = []
        if moved > 0 { parts.append("\(moved) boundary edit\(moved == 1 ? "" : "s")") }
        if added > 0 { parts.append("\(added) added") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if rated > 0 { parts.append("\(rated) rated") }
        if exported > 0 { parts.append("\(exported) export\(exported == 1 ? "" : "s")") }
        return parts.isEmpty ? "No manual adjustments yet" : parts.joined(separator: " · ")
    }

    private func historyRow(_ entry: LedgerEntry, run: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon(for: entry.event))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(describe(entry.event, run: run))
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Text(entry.ts, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func icon(for event: SessionEvent) -> String {
        switch event {
        case .analysisRun: return "wand.and.stars"
        case .pointDeleted: return "trash"
        case .pointRestored: return "arrow.uturn.backward"
        case .pointAdded: return "plus.circle"
        case .boundaryChanged: return "arrow.left.and.right"
        case .highlightRated: return "hand.thumbsup"
        case .pointFeedback: return "exclamationmark.bubble"
        case .serveSideOverridden: return "arrow.left.arrow.right"
        case .pointWinnerOverridden: return "trophy"
        case .gameSplitInserted: return "flag.checkered.2.crossed"
        case .savedToPool: return "square.and.arrow.down.on.square"
        case .exported: return "square.and.arrow.up"
        case .undo: return "arrow.uturn.left"
        case .redo: return "arrow.uturn.right"
        }
    }

    private func describe(_ event: SessionEvent, run: Int) -> String {
        switch event {
        case .analysisRun(let pointCount, let usedHitModel):
            return "Analyzed: \(pointCount) points\(usedHitModel ? " (hit model)" : "")"
        case .pointDeleted(let id):
            return "Deleted \(pointLabel(id, run: run))"
        case .pointRestored(let id):
            return "Restored \(pointLabel(id, run: run))"
        case .pointAdded(_, let start, let end):
            return String(format: "Added point %@ – %@", timestamp(start), timestamp(end))
        case .boundaryChanged(let id, let edge, let from, let to):
            return String(format: "Moved %@ %@ %+.1fs", pointLabel(id, run: run), edge == .start ? "start" : "end", to - from)
        case .highlightRated(let id, let rating):
            switch rating {
            case "up": return "Rated \(pointLabel(id, run: run)) 👍"
            case "down": return "Rated \(pointLabel(id, run: run)) 👎"
            default: return "Cleared rating on \(pointLabel(id, run: run))"
            }
        case .pointFeedback(let id, let reason):
            let label = PointFeedbackReason(rawValue: reason)?.label ?? reason
            return "Feedback on \(pointLabel(id, run: run)): \(label)"
        case .serveSideOverridden(let id, let side):
            let label = ServeDetector.ServeSide(rawValue: side).map { appState.serveABLabel($0, forPointID: id) } ?? side
            return "Pinned serve of \(pointLabel(id, run: run)) to \(label)"
        case .gameSplitInserted(let id):
            return "Started a new game at \(pointLabel(id, run: run))"
        case .pointWinnerOverridden(let id, let side):
            let label = ServeDetector.ServeSide(rawValue: side).map { appState.serveABLabel($0, forPointID: id) } ?? side
            return "Set winner of \(pointLabel(id, run: run)) to \(label)"
        case .savedToPool(let rally, let background):
            return "Saved for training: \(rally) rally + \(background) background clips"
        case .exported(let output):
            return "Exported \(output)"
        case .undo:
            return "Undid last adjustment"
        case .redo:
            return "Redid adjustment"
        }
    }

    private func pointLabel(_ id: UUID, run: Int) -> String {
        if let label = labelsByRun[run]?[id] {
            return label
        }
        if let point = appState.point(withID: id) {
            return "#\(point.pointNumber) (\(timestamp(point.start)))"
        }
        return "a point"
    }

    private func timestamp(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("All versions and adjustments are stored locally on this Mac. Re-analyzing never deletes them — you can always switch back.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Show session folder in Finder") {
                appState.revealSessionFolder()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.top, 4)
    }
}
