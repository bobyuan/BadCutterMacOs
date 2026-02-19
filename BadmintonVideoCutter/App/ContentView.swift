import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, CaseIterable, Identifiable {
    case importTab = "Import"
    case analyze = "Analyze"
    case timeline = "Timeline"
    case stats = "Rm Stats"
    case export = "Export"
    case models = "Models"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .importTab: return "square.and.arrow.down"
        case .analyze: return "waveform.badge.magnifyingglass"
        case .timeline: return "timeline.selection"
        case .stats: return "chart.bar"
        case .export: return "square.and.arrow.up"
        case .models: return "cpu"
        }
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: AppTab = .importTab

    var body: some View {
        TabView(selection: $selectedTab) {
            ImportTabView(appState: appState)
                .tabItem {
                    Label(AppTab.importTab.rawValue, systemImage: AppTab.importTab.icon)
                }
                .tag(AppTab.importTab)

            AnalysisTabView(appState: appState)
                .tabItem {
                    Label(AppTab.analyze.rawValue, systemImage: AppTab.analyze.icon)
                }
                .tag(AppTab.analyze)

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

            ModelsTabView(appState: appState)
                .tabItem {
                    Label(AppTab.models.rawValue, systemImage: AppTab.models.icon)
                }
                .tag(AppTab.models)
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}
