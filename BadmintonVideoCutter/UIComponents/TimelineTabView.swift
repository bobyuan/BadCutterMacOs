import SwiftUI
import AVKit

struct TimelineTabView: View {
    @ObservedObject var appState: AppState
    @State private var viewport = TimelineViewport()
    @State private var playheadTime: TimeInterval = 0
    @State private var timeObserver: Any?
    @State private var previewBoundaryObserver: Any?
    @State private var selectedPointID: UUID?

    var body: some View {
        HSplitView {
            // Left panel: player + timeline + minimap
            VStack(spacing: 12) {
                // Video player with trim overlay
                if let player = appState.player {
                    ZStack {
                        NativePlayerView(player: player)
                            .frame(minHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        // Shuttlecock detection overlay: two concentric circles
                        // Big circle (border only) for easy visibility
                        // Small circle (solid fill) for precise detection point
                        if let pos = shuttlecockPositionAtPlayhead {
                            GeometryReader { geo in
                                let cx = CGFloat(pos.x) * geo.size.width
                                let cy = CGFloat(pos.y) * geo.size.height

                                // Big circle — green border, easy to spot
                                Circle()
                                    .stroke(Color.green, lineWidth: 2.5)
                                    .frame(width: 60, height: 60)
                                    .position(x: cx, y: cy)

                                // Small circle — solid green, detection point
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .position(x: cx, y: cy)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    // Red border when playhead is in a trim (removed) segment
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red, lineWidth: isInTrimZone ? 3 : 0)
                            .allowsHitTesting(false)
                    )
                    .onAppear { setupTimeObserver(player) }
                    .onDisappear { removeTimeObserver(player) }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.gray.opacity(0.15))
                        .overlay(Text("No video loaded").foregroundStyle(.secondary))
                        .frame(minHeight: 280)
                }

                // Confidence graph
                if !appState.featureFrames.isEmpty {
                    ConfidenceGraphView(
                        featureFrames: appState.featureFrames,
                        viewport: viewport,
                        playheadTime: playheadTime
                    )
                    .frame(height: 80)
                    .background(ScrollWheelHandler { deltaX in scrollViewport(deltaX: deltaX) })
                }

                // Interactive trim timeline
                if !appState.segments.isEmpty {
                    TrimOverlayTimelineView(
                        appState: appState,
                        viewport: $viewport,
                        playheadTime: $playheadTime,
                        selectedPointID: $selectedPointID
                    )
                    .frame(height: 60)
                    .background(ScrollWheelHandler { deltaX in scrollViewport(deltaX: deltaX) })
                }

                // Minimap
                if !appState.segments.isEmpty {
                    MinimapView(
                        appState: appState,
                        viewport: $viewport,
                        playheadTime: playheadTime
                    )
                    .frame(height: 30)
                }

                // Horizontal scrollbar (visible when zoomed in)
                if viewport.zoom > 1.0 {
                    TimelineScrollbar(
                        viewport: $viewport,
                        totalDuration: appState.videoMetadata?.duration ?? appState.segments.last?.end ?? 1
                    )
                    .frame(height: 12)
                }

                // Zoom controls
                HStack {
                    Button(action: { viewport.zoomOut(around: playheadTime) }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text(String(format: "%.1fx", viewport.zoom))
                        .font(.caption).monospacedDigit()
                    Button(action: { viewport.zoomIn(around: playheadTime) }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Spacer()
                    Text(formatTime(playheadTime))
                        .font(.caption).monospacedDigit()
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 500)
            .onAppear { resetViewport() }
            .onChange(of: appState.videoMetadata?.duration) { _, _ in resetViewport() }

            // Right panel: Point list
            PointListView(
                appState: appState,
                selectedPointID: selectedPointID,
                playheadTime: playheadTime
            ) { point in
                previewPoint(point)
            }
            .frame(minWidth: 280, maxWidth: 350)
            .onAppear {
                // Trigger serve detection if games exist but scores haven't been computed yet
                if !appState.games.isEmpty && appState.pointScores.isEmpty {
                    appState.detectServesAndScores()
                }
            }
        }
    }

    // MARK: - Trim Zone Detection

    /// True when playhead is inside a trim segment that will be removed.
    private var isInTrimZone: Bool {
        appState.trimSegments.contains { trim in
            trim.reviewStatus != .flagged && playheadTime >= trim.start && playheadTime <= trim.end
        }
    }

    // MARK: - Shuttlecock Position Overlay

    /// Returns the detected shuttlecock position for the current playhead time.
    /// Uses binary search to find the nearest analyzed frame.
    private var shuttlecockPositionAtPlayhead: (x: Double, y: Double)? {
        let frames = appState.featureFrames
        guard !frames.isEmpty else { return nil }

        // Binary search for the nearest frame
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].timestamp < playheadTime {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Check the closest frame (lo or lo-1)
        var bestIdx = lo
        if lo > 0 {
            let dLo = abs(frames[lo].timestamp - playheadTime)
            let dPrev = abs(frames[lo - 1].timestamp - playheadTime)
            if dPrev < dLo { bestIdx = lo - 1 }
        }

        // Only show if the frame is within 0.3s of playhead (don't stale-display)
        guard abs(frames[bestIdx].timestamp - playheadTime) < 0.3 else { return nil }
        return frames[bestIdx].shuttlecockPosition
    }

    private func scrollViewport(deltaX: CGFloat) {
        let totalDuration = appState.videoMetadata?.duration ?? 1
        guard totalDuration > 0 else { return }
        // Convert pixel scroll delta to time shift (scale by visible duration)
        let timeShift = -Double(deltaX) / 500.0 * viewport.visibleDuration
        let newStart = max(0, min(totalDuration - viewport.visibleDuration, viewport.visibleStart + timeShift))
        let newEnd = newStart + viewport.visibleDuration
        viewport.visibleStart = newStart
        viewport.visibleEnd = min(totalDuration, newEnd)
    }

    // MARK: - Time Observer

    private func setupTimeObserver(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            playheadTime = time.seconds
        }
    }

    private func removeTimeObserver(_ player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let obs = previewBoundaryObserver {
            player.removeTimeObserver(obs)
            previewBoundaryObserver = nil
        }
    }

    private func previewPoint(_ point: GamePoint) {
        guard let player = appState.player else { return }

        selectedPointID = point.id

        // Seek to point start
        let startCM = CMTime(seconds: point.start, preferredTimescale: 600)
        player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero)
        playheadTime = point.start

        // Scroll viewport to center on the point segment
        let totalDuration = appState.videoMetadata?.duration ?? 60
        let pointCenter = (point.start + point.end) / 2
        let halfVisible = viewport.visibleDuration / 2
        viewport.visibleStart = max(0, min(pointCenter - halfVisible, totalDuration - viewport.visibleDuration))
        viewport.visibleEnd = viewport.visibleStart + viewport.visibleDuration

        // Remove any existing boundary observer
        if let obs = previewBoundaryObserver {
            player.removeTimeObserver(obs)
            previewBoundaryObserver = nil
        }

        // Auto-play and pause at point end
        let endCM = CMTime(seconds: point.end, preferredTimescale: 600)
        previewBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endCM)],
            queue: .main
        ) { [weak player] in
            player?.pause()
        }
        player.play()
    }

    private func resetViewport() {
        let duration = appState.videoMetadata?.duration ?? 60
        viewport = TimelineViewport(visibleStart: 0, visibleEnd: duration, zoom: 1.0)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, ms)
    }
}

// MARK: - Confidence Graph

struct ConfidenceGraphView: View {
    let featureFrames: [FeatureFrame]
    let viewport: TimelineViewport
    let playheadTime: TimeInterval

    @State private var showMotion = true
    @State private var showAudio = true
    @State private var showShuttle = true

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .topLeading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))

                // Motion line (blue)
                if showMotion {
                    Path { path in
                        drawLine(path: &path, keyPath: \.motionScore, width: width, height: height, color: .blue)
                    }
                    .stroke(Color.blue.opacity(0.7), lineWidth: 1.5)
                }

                // Audio line (orange)
                if showAudio {
                    Path { path in
                        drawLine(path: &path, keyPath: \.audioScore, width: width, height: height, color: .orange)
                    }
                    .stroke(Color.orange.opacity(0.7), lineWidth: 1.5)
                }

                // Shuttlecock flight line (green)
                if showShuttle {
                    Path { path in
                        drawLine(path: &path, keyPath: \.shuttlecockFlightScore, width: width, height: height, color: .green)
                    }
                    .stroke(Color.green.opacity(0.7), lineWidth: 1.5)
                }

                // Playhead
                let px = timeToX(playheadTime, width: width)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1)
                    .offset(x: px)

                // Legend (clickable toggles)
                HStack(spacing: 8) {
                    legendToggle(label: "Motion", color: .blue, isOn: $showMotion)
                    legendToggle(label: "Audio", color: .orange, isOn: $showAudio)
                    legendToggle(label: "Shuttle", color: .green, isOn: $showShuttle)
                }
                .padding(4)
            }
        }
    }

    private func legendToggle(label: String, color: Color, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(isOn.wrappedValue ? 0.7 : 0.2))
                    .frame(width: 12, height: 2)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func drawLine(path: inout Path, keyPath: KeyPath<FeatureFrame, Double>, width: CGFloat, height: CGFloat, color: Color) {
        let visibleFrames = featureFrames.filter {
            $0.timestamp >= viewport.visibleStart && $0.timestamp <= viewport.visibleEnd
        }
        guard !visibleFrames.isEmpty else { return }

        var started = false
        for frame in visibleFrames {
            let x = timeToX(frame.timestamp, width: width)
            let y = height - CGFloat(frame[keyPath: keyPath]) * height
            if !started {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
    }

    private func timeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = viewport.visibleEnd - viewport.visibleStart
        guard duration > 0 else { return 0 }
        return CGFloat((time - viewport.visibleStart) / duration) * width
    }
}

// MARK: - Trim Overlay Timeline

struct TrimOverlayTimelineView: View {
    @ObservedObject var appState: AppState
    @Binding var viewport: TimelineViewport
    @Binding var playheadTime: TimeInterval
    @Binding var selectedPointID: UUID?

    // Boundary-drag tracking for ledger commits (one drag at a time)
    @State private var dragPointID: UUID?
    @State private var dragOriginValue: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.1))

                // Rally blocks (green)
                ForEach(appState.segments.filter { $0.label == .rally }) { seg in
                    let x = timeToX(seg.start, width: width)
                    let w = timeToX(seg.end, width: width) - x
                    Rectangle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: max(1, w), height: height)
                        .offset(x: x)
                }

                // Trim overlays (red, semi-transparent) with drag handles
                ForEach(appState.trimSegments) { trim in
                    let x = timeToX(trim.start, width: width)
                    let w = timeToX(trim.end, width: width) - x

                    // Trim block
                    Rectangle()
                        .fill(trimColor(for: trim).opacity(0.35))
                        .frame(width: max(1, w), height: height)
                        .offset(x: x)

                    // Left drag handle — adjusts the end of the preceding point
                    TrimDragHandle(edge: .leading)
                        .offset(x: x - 4)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newTime = xToTime(value.location.x, width: width)
                                    appState.updateTrimBoundary(trimID: trim.id, newStart: newTime)
                                    if dragPointID == nil,
                                       let pointID = appState.adjacentPointForTrim(trimID: trim.id, edge: .leading) {
                                        dragPointID = pointID
                                        dragOriginValue = appState.point(withID: pointID)?.end
                                    }
                                    if let pointID = dragPointID {
                                        appState.updatePointBoundary(pointID: pointID, newEnd: newTime)
                                        selectedPointID = pointID
                                    }
                                }
                                .onEnded { _ in
                                    if let pointID = dragPointID, let from = dragOriginValue,
                                       let point = appState.point(withID: pointID) {
                                        appState.commitPointBoundary(pointID: pointID, edge: .end, from: from, to: point.end)
                                    }
                                    dragPointID = nil
                                    dragOriginValue = nil
                                }
                        )

                    // Right drag handle — adjusts the start of the following point
                    TrimDragHandle(edge: .trailing)
                        .offset(x: x + max(1, w) - 4)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newTime = xToTime(value.location.x, width: width)
                                    appState.updateTrimBoundary(trimID: trim.id, newEnd: newTime)
                                    if dragPointID == nil,
                                       let pointID = appState.adjacentPointForTrim(trimID: trim.id, edge: .trailing) {
                                        dragPointID = pointID
                                        dragOriginValue = appState.point(withID: pointID)?.start
                                    }
                                    if let pointID = dragPointID {
                                        appState.updatePointBoundary(pointID: pointID, newStart: newTime)
                                        selectedPointID = pointID
                                    }
                                }
                                .onEnded { _ in
                                    if let pointID = dragPointID, let from = dragOriginValue,
                                       let point = appState.point(withID: pointID) {
                                        appState.commitPointBoundary(pointID: pointID, edge: .start, from: from, to: point.start)
                                    }
                                    dragPointID = nil
                                    dragOriginValue = nil
                                }
                        )
                }

                // Game break bands (blue semi-transparent)
                ForEach(appState.games.filter { $0.breakAfter != nil }) { game in
                    if let brk = game.breakAfter {
                        let x = timeToX(brk.start, width: width)
                        let w = timeToX(brk.end, width: width) - x
                        Rectangle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: max(1, w), height: height)
                            .offset(x: x)
                            .allowsHitTesting(false)
                    }
                }

                // Playhead
                let px = timeToX(playheadTime, width: width)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .offset(x: px)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let time = xToTime(location.x, width: width)
                seekTo(time)
            }
        }
    }

    private func timeToX(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        let duration = viewport.visibleEnd - viewport.visibleStart
        guard duration > 0 else { return 0 }
        return CGFloat((time - viewport.visibleStart) / duration) * width
    }

    private func xToTime(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        let duration = viewport.visibleEnd - viewport.visibleStart
        guard width > 0 else { return viewport.visibleStart }
        return viewport.visibleStart + Double(x / width) * duration
    }

    private func seekTo(_ time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        appState.player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        playheadTime = time
    }

    private func trimColor(for trim: TrimSegment) -> Color {
        switch trim.reviewStatus {
        case .accepted: return .red
        case .flagged: return .yellow
        case .unreviewed: return .red
        }
    }
}

// MARK: - Trim Drag Handle

struct TrimDragHandle: View {
    let edge: HorizontalEdge

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.9))
            .frame(width: 8, height: 50)
            .shadow(radius: 2)
            .cursor(.resizeLeftRight)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Minimap

// MARK: - Horizontal Scrollbar

struct TimelineScrollbar: View {
    @Binding var viewport: TimelineViewport
    let totalDuration: TimeInterval

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let thumbFraction = CGFloat(viewport.visibleDuration / max(totalDuration, 1))
            let thumbWidth = max(30, trackWidth * thumbFraction)
            let scrollableWidth = trackWidth - thumbWidth
            let thumbOffset = totalDuration > viewport.visibleDuration
                ? CGFloat(viewport.visibleStart / (totalDuration - viewport.visibleDuration)) * scrollableWidth
                : 0

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))

                // Thumb
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(isDragging ? 0.6 : 0.4))
                    .frame(width: thumbWidth)
                    .offset(x: thumbOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                let newOffset = max(0, min(scrollableWidth, thumbOffset + value.translation.width))
                                let fraction = scrollableWidth > 0 ? Double(newOffset / scrollableWidth) : 0
                                let maxStart = totalDuration - viewport.visibleDuration
                                let newStart = max(0, min(maxStart, fraction * maxStart))
                                viewport.visibleStart = newStart
                                viewport.visibleEnd = newStart + viewport.visibleDuration
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            }
            // Click on track to jump
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = Double(location.x / trackWidth)
                let maxStart = totalDuration - viewport.visibleDuration
                let newStart = max(0, min(maxStart, fraction * maxStart))
                viewport.visibleStart = newStart
                viewport.visibleEnd = newStart + viewport.visibleDuration
            }
        }
    }
}

// MARK: - Scroll Wheel Handler (macOS trackpad / mouse wheel)

struct ScrollWheelHandler: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }

    class ScrollWheelNSView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // Use horizontal scroll delta (trackpad two-finger swipe or shift+scroll wheel)
            let dx = event.scrollingDeltaX
            if abs(dx) > 0.1 {
                onScroll?(dx)
            }
        }
    }
}

// MARK: - Minimap

struct MinimapView: View {
    @ObservedObject var appState: AppState
    @Binding var viewport: TimelineViewport
    let playheadTime: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let totalDuration = appState.videoMetadata?.duration ?? appState.segments.last?.end ?? 1

            ZStack(alignment: .leading) {
                // Full timeline segments
                HStack(spacing: 0) {
                    ForEach(appState.segments) { seg in
                        let fraction = seg.duration / totalDuration
                        Rectangle()
                            .fill(seg.label == .rally ? Color.green.opacity(0.6) : Color.red.opacity(0.3))
                            .frame(width: max(1, width * CGFloat(fraction)))
                    }
                }

                // Viewport indicator
                let vpStart = CGFloat(viewport.visibleStart / totalDuration) * width
                let vpEnd = CGFloat(viewport.visibleEnd / totalDuration) * width
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1)))
                    .frame(width: max(10, vpEnd - vpStart))
                    .offset(x: vpStart)

                // Game labels
                ForEach(appState.games) { game in
                    if let firstPoint = game.points.first {
                        let gx = CGFloat(firstPoint.start / totalDuration) * width
                        Text("G\(game.gameNumber)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: gx + 2, y: 1)
                    }
                }

                // Playhead
                let px = CGFloat(playheadTime / totalDuration) * width
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1)
                    .offset(x: px)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let fraction = Double(value.location.x / width)
                        let center = fraction * totalDuration
                        let halfVisible = viewport.visibleDuration / 2
                        viewport.visibleStart = max(0, center - halfVisible)
                        viewport.visibleEnd = min(totalDuration, center + halfVisible)
                    }
            )
        }
    }
}

