import Foundation

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var videoItems: [VideoItem] = []
    @Published var currentAssetURL: URL?
    @Published var isShowingFileImporter = false
    @Published var isAnalyzing = false
    @Published var isExporting = false
    @Published var statusMessage: String?
    @Published var lastErrorMessage: String?
    @Published var sensitivity: SensitivityPreset = .aggressive
    @Published var segments: [TimeSegment] = []

    private let exporter = VideoExporter()

    func importVideo() {
        isShowingFileImporter = true
    }

    func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let item = VideoItem(displayName: url.lastPathComponent, url: url)
            videoItems.append(item)
            currentAssetURL = url
            statusMessage = "Loaded \(url.lastPathComponent)"
            lastErrorMessage = nil

        case .failure(let error):
            lastErrorMessage = error.localizedDescription
        }
    }

    func analyzeCurrentVideo() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        isAnalyzing = true
        statusMessage = "Analyzing…"
        lastErrorMessage = nil

        Task {
            do {
                let pipeline = AnalysisPipelineImpl(
                    extractor: BasicFeatureExtractor(),
                    classifier: HybridSegmenter(),
                    postProcessor: HybridSegmenter()
                )
                let config = AnalysisConfig(rallyPercentile: sensitivity.rallyPercentile)
                let result = try await pipeline.analyze(videoURL: url, config: config)
                self.segments = result
                self.statusMessage = "Analysis complete: \(result.filter { $0.label == .rally }.count) rally segments"
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            self.isAnalyzing = false
        }
    }

    func exportRallyOnly() {
        guard let url = currentAssetURL else {
            lastErrorMessage = "Load a video first."
            return
        }
        guard segments.contains(where: { $0.label == .rally }) else {
            lastErrorMessage = "No rally segments found. Run analysis first."
            return
        }

        isExporting = true
        statusMessage = "Exporting rally-only video…"
        lastErrorMessage = nil

        Task {
            do {
                let output = try await exporter.exportRallyOnly(assetURL: url, segments: segments)
                self.statusMessage = "Exported: \(output.lastPathComponent)"
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            self.isExporting = false
        }
    }
}
