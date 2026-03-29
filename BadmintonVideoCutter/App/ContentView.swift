import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, CaseIterable, Identifiable {
    case videos = "Videos"
    case timeline = "Timeline"
    case stats = "Rm Stats"
    case export = "Export"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .videos: return "film.stack"
        case .timeline: return "timeline.selection"
        case .stats: return "chart.bar"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: AppTab = .videos

    var body: some View {
        TabView(selection: $selectedTab) {
            VideosTabView(appState: appState)
                .tabItem {
                    Label(AppTab.videos.rawValue, systemImage: AppTab.videos.icon)
                }
                .tag(AppTab.videos)

            TimelineTabView(appState: appState)
                .tabItem {
                    Label(AppTab.timeline.rawValue, systemImage: AppTab.timeline.icon)
                }
                .tag(AppTab.timeline)

            RemovalStatsTabView(appState: appState)
                .tabItem {
                    Label(AppTab.stats.rawValue, systemImage: AppTab.stats.icon)
                }
                .tag(AppTab.stats)

            ExportTabView(appState: appState)
                .tabItem {
                    Label(AppTab.export.rawValue, systemImage: AppTab.export.icon)
                }
                .tag(AppTab.export)
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}
