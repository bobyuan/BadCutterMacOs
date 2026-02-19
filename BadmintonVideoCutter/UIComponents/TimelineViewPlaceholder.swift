import SwiftUI

struct TimelineViewPlaceholder: View {
    let segments: [TimeSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline (Placeholder)").font(.headline)
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(color(for: segment.label))
                        .frame(width: max(10, segment.duration * 8), height: 40)
                        .overlay(Text(segment.label.rawValue).font(.caption2).foregroundStyle(.white))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for label: SegmentLabel) -> Color {
        switch label {
        case .rally: return .red
        case .betweenPoints: return .green
        case .unknown: return .gray
        }
    }
}
