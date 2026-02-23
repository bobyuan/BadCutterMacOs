import SwiftUI

struct CalibrationView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HSplitView {
            CalibrationFrameViewer(appState: appState)
                .frame(minWidth: 500)

            CalibrationFrameList(appState: appState)
                .frame(minWidth: 250, maxWidth: 350)
        }
    }
}

// MARK: - Frame Viewer (Left Panel)

struct CalibrationFrameViewer: View {
    @ObservedObject var appState: AppState
    @State private var dragPosition: CGPoint? = nil

    private var selectedFrame: CalibrationFrame? {
        guard let id = appState.selectedCalibrationFrameID else { return nil }
        return appState.calibrationFrames.first { $0.id == id }
    }

    private var selectedImage: CGImage? {
        guard let id = appState.selectedCalibrationFrameID else { return nil }
        return appState.calibrationImages[id]
    }

    var body: some View {
        VStack(spacing: 16) {
            if let frame = selectedFrame {
                // Header with timestamp and status
                HStack {
                    Text(formatTime(frame.timestamp))
                        .font(.title3).bold().monospacedDigit()
                    Spacer()
                    statusBadge(for: frame.status)
                }

                // Image with draggable rectangle
                if let cgImage = selectedImage {
                    GeometryReader { geo in
                        let imageSize = fitImageSize(cgImage: cgImage, in: geo.size)
                        let origin = CGPoint(
                            x: (geo.size.width - imageSize.width) / 2,
                            y: (geo.size.height - imageSize.height) / 2
                        )

                        ZStack(alignment: .topLeading) {
                            Image(decorative: cgImage, scale: 1.0)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imageSize.width, height: imageSize.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                            // Green rectangle overlay
                            if let pos = currentPosition(for: frame) {
                                let boxW = frame.boxSize.width * imageSize.width
                                let boxH = frame.boxSize.height * imageSize.height
                                let cx = origin.x + pos.x * imageSize.width
                                let cy = origin.y + pos.y * imageSize.height

                                Rectangle()
                                    .stroke(Color.green, lineWidth: 2.5)
                                    .frame(width: boxW, height: boxH)
                                    .position(x: cx, y: cy)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let normX = (value.location.x - origin.x) / imageSize.width
                                    let normY = (value.location.y - origin.y) / imageSize.height
                                    let clamped = CGPoint(
                                        x: max(0, min(1, normX)),
                                        y: max(0, min(1, normY))
                                    )
                                    dragPosition = clamped
                                }
                                .onEnded { value in
                                    let normX = (value.location.x - origin.x) / imageSize.width
                                    let normY = (value.location.y - origin.y) / imageSize.height
                                    let clamped = CGPoint(
                                        x: max(0, min(1, normX)),
                                        y: max(0, min(1, normY))
                                    )
                                    dragPosition = clamped
                                }
                        )
                    }
                } else {
                    // Loading placeholder
                    VStack {
                        Spacer()
                        ProgressView("Loading frame...")
                        Spacer()
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: confirmPosition) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm Position")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(currentPosition(for: frame) == nil)

                    Button(action: markNotVisible) {
                        HStack {
                            Image(systemName: "eye.slash")
                            Text("Not Visible")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            } else {
                Spacer()
                Text("Select a frame from the list")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .onChange(of: appState.selectedCalibrationFrameID) { _, _ in
            dragPosition = nil
        }
    }

    private func currentPosition(for frame: CalibrationFrame) -> CGPoint? {
        dragPosition ?? frame.shuttlecockPosition
    }

    private func confirmPosition() {
        guard let id = appState.selectedCalibrationFrameID,
              let frame = selectedFrame,
              let pos = currentPosition(for: frame) else { return }
        appState.setCalibrationLabel(frameID: id, position: pos)
        dragPosition = nil
        advanceToNextFrame()
    }

    private func markNotVisible() {
        guard let id = appState.selectedCalibrationFrameID else { return }
        appState.setCalibrationNotVisible(frameID: id)
        dragPosition = nil
        advanceToNextFrame()
    }

    private func advanceToNextFrame() {
        guard let currentID = appState.selectedCalibrationFrameID,
              let idx = appState.calibrationFrames.firstIndex(where: { $0.id == currentID }) else { return }
        // Find next unlabeled frame
        let remaining = appState.calibrationFrames[(idx + 1)...]
        if let next = remaining.first(where: { $0.status == .unlabeled }) {
            appState.selectedCalibrationFrameID = next.id
        }
    }

    private func fitImageSize(cgImage: CGImage, in containerSize: CGSize) -> CGSize {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let scaleW = containerSize.width / imgW
        let scaleH = containerSize.height / imgH
        let scale = min(scaleW, scaleH)
        return CGSize(width: imgW * scale, height: imgH * scale)
    }

    private func statusBadge(for status: CalibrationStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: CalibrationStatus) -> Color {
        switch status {
        case .unlabeled: return .gray
        case .labeled: return .green
        case .notVisible: return .orange
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, ms)
    }
}

// MARK: - Frame List (Right Panel)

struct CalibrationFrameList: View {
    @ObservedObject var appState: AppState

    private var labeledCount: Int {
        appState.calibrationFrames.filter { $0.status != .unlabeled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Calibration Frames")
                    .font(.headline)
                Spacer()
                Text("\(labeledCount)/\(appState.calibrationFrames.count) labeled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Re-analyze button (visible when any frames are labeled)
            if appState.calibrationFrames.contains(where: { $0.status == .labeled }) {
                Button(action: { appState.reAnalyzeWithCalibration() }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Re-analyze with Calibration")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.regular)
                .disabled(appState.isAnalyzing)
                .padding(.horizontal, 12)
            }

            if appState.calibrationFrames.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "target")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No calibration frames yet")
                        .foregroundStyle(.secondary)
                    Button("Generate Frames") {
                        appState.generateCalibrationFrames()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Scrollable list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(appState.calibrationFrames) { frame in
                                CalibrationFrameRow(
                                    frame: frame,
                                    thumbnail: appState.calibrationImages[frame.id],
                                    isSelected: appState.selectedCalibrationFrameID == frame.id
                                )
                                .id(frame.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.selectedCalibrationFrameID = frame.id
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: appState.selectedCalibrationFrameID) { _, newID in
                        if let id = newID {
                            withAnimation {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Frame Row

struct CalibrationFrameRow: View {
    let frame: CalibrationFrame
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let cgImage = thumbnail {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 34)
                    .overlay(
                        ProgressView().controlSize(.mini)
                    )
            }

            // Timestamp
            Text(formatTime(frame.timestamp))
                .font(.callout).monospacedDigit()

            Spacer()

            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
    }

    private var statusColor: Color {
        switch frame.status {
        case .unlabeled: return .gray
        case .labeled: return .green
        case .notVisible: return .orange
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
