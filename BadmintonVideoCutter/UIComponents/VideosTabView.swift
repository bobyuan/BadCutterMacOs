import SwiftUI
import UniformTypeIdentifiers

struct VideosTabView: View {
    @ObservedObject var appState: AppState
    @State private var showCalibration = false

    var body: some View {
        HSplitView {
            leftPanel
            rightPanel
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Videos")
                .font(.title2).bold()

            dropZone

            Button("Choose File...") {
                appState.isShowingFileImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider()

            if !appState.videoItems.isEmpty {
                videoListSection
            } else {
                Text("No videos loaded yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Divider()

            controlsSection

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 350)
        .fileImporter(
            isPresented: $appState.isShowingFileImporter,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    appState.loadVideo(url: url)
                }
            case .failure(let error):
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .foregroundStyle(.secondary)
            .frame(height: 80)
            .overlay {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop video files here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("MOV, MP4, M4V")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .onDrop(of: [.movie, .video, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard ["mov", "mp4", "m4v", "avi"].contains(ext) else { return }
                Task { @MainActor in
                    appState.loadVideo(url: url)
                }
            }
        }
    }

    // MARK: - Video List

    private var videoListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select All") { appState.selectAllVideos() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Select None") { appState.selectNoVideos() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }

            List {
                ForEach(appState.videoItems) { item in
                    videoRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectVideo(url: item.url)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                appState.removeVideo(id: item.id)
                            } label: {
                                Label("Remove from List", systemImage: "trash")
                            }
                        }
                }
                .onMove { source, destination in
                    appState.moveVideo(from: source, to: destination)
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        appState.removeVideo(id: appState.videoItems[idx].id)
                    }
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: 250)
        }
    }

    private func videoRow(item: VideoItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { newVal in
                    if let idx = appState.videoItems.firstIndex(where: { $0.id == item.id }) {
                        appState.videoItems[idx].isSelected = newVal
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            statusIcon(for: item.url)

            Text(item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if item.url == appState.currentAssetURL {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .background(item.url == appState.currentAssetURL
            ? Color.accentColor.opacity(0.1)
            : Color.clear)
        .cornerRadius(4)
    }

    @ViewBuilder
    private func statusIcon(for url: URL) -> some View {
        switch appState.analysisStatus(for: url) {
        case .notAnalyzed:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 10, height: 10)
        case .analyzing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            // ML Shuttlecock Detection status
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.hasShuttlecockModel ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(appState.hasShuttlecockModel ? "ML Shuttlecock Detection: Active" : "ML Model Not Found")
                    .font(.caption)
                    .foregroundStyle(appState.hasShuttlecockModel ? .primary : .secondary)
            }

            analyzeButton

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            hitDetectionTrainingSection
        }
    }

    private var analyzeButton: some View {
        let selectedCount = appState.videoItems.filter(\.isSelected).count

        return Button(action: { appState.analyzeBatch() }) {
            HStack {
                if appState.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                }
                if appState.isBatchAnalyzing {
                    Text("Analyzing \(appState.batchIndex + 1) of \(appState.batchQueue.count)...")
                } else if appState.isAnalyzing {
                    Text("Analyzing...")
                } else {
                    Text("Analyze Selected (\(selectedCount))")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(appState.isAnalyzing || selectedCount == 0)
    }

    private var sensitivityDescription: String {
        switch appState.sensitivity {
        case .conservative: return "Keeps more content. Better for short rallies."
        case .balanced: return "Good balance between precision and recall."
        case .aggressive: return "Removes more between-points. Best for long rallies."
        }
    }

    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        if showCalibration {
            VStack(spacing: 0) {
                HStack {
                    Button("Results") { showCalibration = false }
                        .buttonStyle(.bordered)
                    Button("Calibration") { }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

                CalibrationView(appState: appState)
            }
            .frame(minWidth: 400)
        } else {
            VStack(spacing: 16) {
                metadataSection

                if appState.isAnalyzing {
                    progressView
                } else if !appState.segments.isEmpty {
                    resultsView
                } else if appState.currentAssetURL != nil {
                    placeholderView("Select videos and click Analyze")
                } else {
                    placeholderView("Import a video to get started")
                }
            }
            .padding(24)
            .frame(minWidth: 400)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataSection: some View {
        if let meta = appState.videoMetadata {
            DisclosureGroup("Video Info") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(meta.formattedDuration).bold()
                    }
                    GridRow {
                        Text("Resolution").foregroundStyle(.secondary)
                        Text(meta.formattedResolution).bold()
                    }
                    GridRow {
                        Text("Codec").foregroundStyle(.secondary)
                        Text(meta.codec).bold()
                    }
                    GridRow {
                        Text("Frame Rate").foregroundStyle(.secondary)
                        Text(String(format: "%.1f fps", meta.frameRate)).bold()
                    }
                    GridRow {
                        Text("File Size").foregroundStyle(.secondary)
                        Text(meta.formattedFileSize).bold()
                    }
                    GridRow {
                        Text("Audio").foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: meta.hasAudio ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(meta.hasAudio ? .green : .red)
                            Text(meta.hasAudio ? "Present" : "None")
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        let progress = appState.analysisProgress

        return VStack(spacing: 20) {
            Text("Analyzing Video")
                .font(.title3).bold()

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

            if progress.stage == .extracting {
                GroupBox {
                    VStack(spacing: 12) {
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

            if progress.stage == .finalizing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scoring and classifying segments...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("Elapsed: \(formatElapsed(progress.elapsedSeconds))")
                    .monospacedDigit()
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if progress.overallProgress > 0.01, progress.elapsedSeconds > 2 {
                let remaining = (progress.elapsedSeconds / progress.overallProgress) * (1.0 - progress.overallProgress)
                HStack {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                    Text("Remaining: ~\(formatElapsed(remaining))")
                        .monospacedDigit()
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

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

            Button(action: {
                if appState.calibrationFrames.isEmpty {
                    appState.generateCalibrationFrames()
                }
                showCalibration = true
            }) {
                HStack {
                    Image(systemName: "target")
                    Text("Calibrate Shuttlecock")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

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

    private func placeholderView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Hit Detection Training

    private var hitDetectionTrainingSection: some View {
        GroupBox("Audio Hit Detection") {
            VStack(alignment: .leading, spacing: 10) {
                hitModelStatusRow
                Divider()
                trainingPoolInfoView
                trainingActionButtons
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var hitModelStatusRow: some View {
        switch appState.hitModelStatus {
        case .notTrained:
            HStack(spacing: 6) {
                Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Text("Sound Model: Not Trained")
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
                    Text(String(format: "Sound Model: Trained (%d clips, %.0f%%)", clipCount, accuracy * 100))
                        .font(.caption)
                } else {
                    Text("Sound Model: Trained (previous session)")
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
            Text("No audio training data. Use the Timeline tab to review points, then Save for Training.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(manifest.videos.count) video(s) in pool: \(manifest.totalRallyClips) rally + \(manifest.totalBackgroundClips) background clips")
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

    // MARK: - Helpers

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
