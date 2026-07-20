import SwiftUI

/// Shared playback/selection state between the center pane (player + timeline)
/// and the inspector (point list). One instance per window.
@MainActor
final class TimelineController: ObservableObject {
    @Published var viewport = TimelineViewport()
    @Published var playheadTime: TimeInterval = 0
    @Published var selectedPointID: UUID? {
        didSet {
            // Selecting a different point drops any stale feedback-tuning
            // state (ghost boundaries + tune bar) from the previous one.
            if let tuning = tuningPointID, tuning != selectedPointID {
                endTuning()
            }
        }
    }

    // MARK: Point tuning (feedback-driven adjustment)
    @Published var tuningPointID: UUID?
    /// Pre-adjustment boundaries, drawn as ghosts while tuning.
    @Published var ghostStart: TimeInterval?
    @Published var ghostEnd: TimeInterval?

    /// Registered by PlayerTimelinePane; invoked from the inspector's point list.
    var previewHandler: ((GamePoint) -> Void)?

    func preview(_ point: GamePoint) {
        previewHandler?(point)
    }

    /// Focus the tune UI on a point: select it and zoom the viewport to
    /// the point ± context.
    func beginTuning(point: GamePoint, ghostStart: TimeInterval?, ghostEnd: TimeInterval?, videoDuration: TimeInterval) {
        tuningPointID = point.id
        selectedPointID = point.id
        self.ghostStart = ghostStart
        self.ghostEnd = ghostEnd
        let lo = max(0, min(point.start, ghostStart ?? point.start) - 8)
        let hi = min(videoDuration, max(point.end, ghostEnd ?? point.end) + 8)
        viewport.visibleStart = lo
        viewport.visibleEnd = hi
        viewport.zoom = max(1.0, videoDuration / max(1, hi - lo))
    }

    func endTuning() {
        tuningPointID = nil
        ghostStart = nil
        ghostEnd = nil
    }
}

/// v2 "Studio" layout: one window, three panes.
/// Library (videos + analyze) | Player + Timeline | Inspector (Points/Export/Models)
struct StudioView: View {
    @ObservedObject var appState: AppState
    @StateObject private var timeline = TimelineController()
    @State private var showCalibration = false

    var body: some View {
        HSplitView {
            LibraryPane(appState: appState)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            PlayerTimelinePane(appState: appState, controller: timeline)
                .frame(minWidth: 480, maxWidth: .infinity)
                .layoutPriority(1)

            InspectorPane(appState: appState, controller: timeline, showCalibration: $showCalibration)
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
        }
        .frame(minWidth: 1160, minHeight: 700)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .sheet(isPresented: $showCalibration) {
            VStack(spacing: 0) {
                HStack {
                    Text("Shuttlecock Calibration")
                        .font(.headline)
                    Spacer()
                    Button("Done") { showCalibration = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                CalibrationView(appState: appState)
            }
            .frame(minWidth: 900, idealWidth: 1000, minHeight: 620, idealHeight: 700)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = appState.lastErrorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let status = appState.statusMessage {
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if appState.isExporting {
                ProgressView().controlSize(.mini)
                Text("Exporting…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
