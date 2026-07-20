import SwiftUI
import UniformTypeIdentifiers

/// Left pane of the Studio layout: video library, sensitivity preset,
/// analyze action, and compact analysis progress.
struct LibraryPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dropZone

            if appState.videoItems.isEmpty {
                Text("No videos yet — drop files or click +")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                videoList
            }

            Divider()

            presetSection
            mlStatusRow
            analyzeButton

            if appState.isAnalyzing {
                analysisProgress
            }

            Spacer(minLength: 0)

            metadataSection
        }
        .padding(14)
        .fileImporter(
            isPresented: $appState.isShowingFileImporter,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls { appState.loadVideo(url: url) }
            case .failure(let error):
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Library")
                .font(.headline)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    appState.selectAllVideos()
                } label: {
                    Image(systemName: "checklist.checked")
                }
                .help("Select all videos")
                Button {
                    appState.selectNoVideos()
                } label: {
                    Image(systemName: "checklist.unchecked")
                }
                .help("Select no videos")
                Button {
                    appState.isShowingFileImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Import videos…")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.tertiary)
            .frame(height: 44)
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .foregroundStyle(.secondary)
                    Text("Drop videos here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var videoList: some View {
        List {
            ForEach(appState.videoItems) { item in
                videoRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.selectVideo(url: item.url) }
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
        .listStyle(.plain)
        .frame(minHeight: 120, maxHeight: 260)
    }

    private func videoRow(item: VideoItem) -> some View {
        HStack(spacing: 6) {
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
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.vertical, 1)
        .listRowBackground(item.url == appState.currentAssetURL
            ? Color.accentColor.opacity(0.15)
            : Color.clear)
    }

    @ViewBuilder
    private func statusIcon(for url: URL) -> some View {
        switch appState.analysisStatus(for: url) {
        case .notAnalyzed:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
        case .analyzing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 8, height: 8)
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

    // MARK: - Analysis Controls

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Sensitivity", selection: $appState.sensitivity) {
                ForEach(SensitivityPreset.allCases) { preset in
                    Text(preset.rawValue.capitalized).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(sensitivityDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sensitivityDescription: String {
        switch appState.sensitivity {
        case .conservative: return "Keeps more content. Better for short rallies."
        case .balanced: return "Good balance between precision and recall."
        case .aggressive: return "Removes more between-points. Best for long rallies."
        }
    }

    private var mlStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appState.hasShuttlecockModel ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(appState.hasShuttlecockModel ? "Shuttle tracking: ML" : "Shuttle tracking: heuristic")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var analyzeButton: some View {
        let selectedCount = appState.videoItems.filter(\.isSelected).count

        return Button(action: { appState.analyzeBatch() }) {
            HStack {
                if appState.isAnalyzing {
                    ProgressView().controlSize(.small)
                }
                if appState.isBatchAnalyzing {
                    Text("Analyzing \(appState.batchIndex + 1) of \(appState.batchQueue.count)…")
                } else if appState.isAnalyzing {
                    Text("Analyzing…")
                } else {
                    Text("Analyze Selected (\(selectedCount))")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(appState.isAnalyzing || selectedCount == 0)
    }

    // MARK: - Progress

    private var analysisProgress: some View {
        let progress = appState.analysisProgress

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Overall")
                    .font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", progress.overallProgress * 100))
                    .font(.caption).bold().monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            ProgressView(value: progress.overallProgress)

            if progress.stage == .extracting {
                HStack(spacing: 4) {
                    Image(systemName: "film").font(.caption2).foregroundStyle(.blue)
                    ProgressView(value: progress.videoProgress)
                    Text(String(format: "%.0f%%", progress.videoProgress * 100))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "waveform").font(.caption2).foregroundStyle(.orange)
                    ProgressView(value: progress.audioProgress)
                    Text(String(format: "%.0f%%", progress.audioProgress * 100))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Elapsed: \(formatElapsed(progress.elapsedSeconds))")
                Spacer()
                if progress.overallProgress > 0.01, progress.elapsedSeconds > 2 {
                    let remaining = (progress.elapsedSeconds / progress.overallProgress) * (1.0 - progress.overallProgress)
                    Text("~\(formatElapsed(remaining)) left")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataSection: some View {
        if let meta = appState.videoMetadata {
            DisclosureGroup {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(meta.formattedDuration)
                    }
                    GridRow {
                        Text("Resolution").foregroundStyle(.secondary)
                        Text(meta.formattedResolution)
                    }
                    GridRow {
                        Text("Codec").foregroundStyle(.secondary)
                        Text("\(meta.codec) @ \(String(format: "%.0f", meta.frameRate))fps")
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(meta.formattedFileSize)
                    }
                    GridRow {
                        Text("Audio").foregroundStyle(.secondary)
                        Text(meta.hasAudio ? "Present" : "None")
                            .foregroundStyle(meta.hasAudio ? .primary : Color.red)
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                Text("Video Info")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        if mins > 0 { return String(format: "%d:%02d", mins, secs) }
        return String(format: "%ds", secs)
    }
}
