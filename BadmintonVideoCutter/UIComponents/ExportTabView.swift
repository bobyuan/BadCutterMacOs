import SwiftUI

struct ExportTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HSplitView {
            // Left: Export settings
            VStack(alignment: .leading, spacing: 20) {
                Text("Export")
                    .font(.title2).bold()

                if appState.currentAssetURL == nil {
                    noVideoView
                } else {
                    settingsView
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 320)

            // Right: Export summary
            VStack(alignment: .leading, spacing: 16) {
                if let stats = appState.removalStatistics {
                    summaryView(stats: stats)
                } else {
                    placeholderView
                }
            }
            .padding(24)
            .frame(minWidth: 400)
        }
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Export Mode") {
                Picker("Mode", selection: $appState.exportConfig.mode) {
                    ForEach(ExportMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 4)
            }

            GroupBox("Transition") {
                Picker("Style", selection: $appState.exportConfig.transition) {
                    ForEach(TransitionStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 4)
            }

            GroupBox("Format") {
                Toggle("Match source format", isOn: $appState.exportConfig.matchSourceFormat)
                    .padding(.vertical, 4)
                if let meta = appState.videoMetadata {
                    Text("Source: \(meta.codec) \(meta.formattedResolution)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: { appState.exportRallyOnly() }) {
                HStack {
                    if appState.isExporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appState.isExporting ? "Exporting..." : "Export Video")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isExporting || appState.segments.isEmpty)

            if let status = appState.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text("Import and analyze a video first")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Summary

    private func summaryView(stats: RemovalStatistics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Summary")
                .font(.title3).bold()

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        Text("Input Duration").foregroundStyle(.secondary)
                        Text(formatDuration(stats.originalDuration)).bold()
                    }
                    GridRow {
                        Text("Output Duration").foregroundStyle(.secondary)
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
                        Text("Gaps Removed").foregroundStyle(.secondary)
                        Text("\(stats.trimCount)").bold()
                    }
                }
                .padding(8)
            }

            if let meta = appState.videoMetadata {
                GroupBox("Output Estimate") {
                    VStack(alignment: .leading, spacing: 8) {
                        let estimatedSize = Double(meta.fileSize) * (stats.keptPercent / 100)
                        HStack {
                            Text("Estimated Size")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(estimatedSize), countStyle: .file))
                                .bold()
                        }
                        HStack {
                            Text("Format")
                            Spacer()
                            Text("MOV (\(meta.codec))")
                                .bold()
                        }
                    }
                    .font(.callout)
                    .padding(4)
                }
            }

            // Flagged trims warning
            let flagged = appState.trimSegments.filter { $0.reviewStatus == .flagged }.count
            if flagged > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("\(flagged) trim segment(s) flagged to keep — these sections will be included in the output.")
                        .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.yellow.opacity(0.1)))
            }

            Spacer()
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Analyze a video to see export summary")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
