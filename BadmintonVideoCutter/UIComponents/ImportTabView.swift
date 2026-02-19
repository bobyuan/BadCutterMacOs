import SwiftUI
import UniformTypeIdentifiers

struct ImportTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HSplitView {
            // Left: Drop zone + file picker
            VStack(spacing: 20) {
                Text("Import Video")
                    .font(.title2).bold()

                dropZone

                Button("Choose File...") {
                    appState.isShowingFileImporter = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let status = appState.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = appState.lastErrorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Divider()

                // Loaded videos list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Loaded Videos")
                        .font(.headline)

                    if appState.videoItems.isEmpty {
                        Text("No videos loaded yet.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        List(appState.videoItems) { item in
                            HStack {
                                Image(systemName: "film")
                                Text(item.displayName)
                                    .lineLimit(1)
                                if item.url == appState.currentAssetURL {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 350)
            .fileImporter(
                isPresented: $appState.isShowingFileImporter,
                allowedContentTypes: [.movie, .video],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let first = urls.first {
                        appState.loadVideo(url: first)
                    }
                case .failure(let error):
                    appState.lastErrorMessage = error.localizedDescription
                }
            }

            // Right: Metadata panel
            VStack(spacing: 16) {
                if let meta = appState.videoMetadata {
                    metadataPanel(meta)
                } else if appState.currentAssetURL != nil {
                    ProgressView("Loading metadata...")
                } else {
                    placeholderPanel
                }
            }
            .padding(24)
            .frame(minWidth: 400)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .foregroundStyle(.secondary)
            .frame(height: 160)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Drop video file here")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("MOV, MP4, M4V")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    // MARK: - Metadata Panel

    private func metadataPanel(_ meta: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Video Information")
                .font(.title3).bold()

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
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

            if let url = appState.currentAssetURL {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File Path").font(.caption).foregroundStyle(.secondary)
                        Text(url.path)
                            .font(.caption)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(4)
                }
            }

            Spacer()
        }
    }

    private var placeholderPanel: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Import a video to see metadata")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
