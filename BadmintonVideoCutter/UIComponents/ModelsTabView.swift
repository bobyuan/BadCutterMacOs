import SwiftUI

struct ModelsTabView: View {
    @State private var importError: String?
    @State private var showImportSuccess = false

    private let modelService = ModelPackageService()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Model Management")
                .font(.title2).bold()

            Text("Using built-in heuristic segmenter")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Custom CoreML models for rally detection can be imported here in a future update.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: 16) {
                Button("Import Model Package...") {
                    // Placeholder
                    importError = "Model import is not yet implemented."
                }
                .buttonStyle(.bordered)

                Button("Export Active Model...") {
                    // Placeholder
                    importError = "Model export is not yet implemented."
                }
                .buttonStyle(.bordered)
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Active Model")
                        Spacer()
                        Text("Built-in Heuristic")
                            .bold()
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                    }
                    HStack {
                        Text("Type")
                        Spacer()
                        Text("Motion + Audio (non-ML)")
                    }
                }
                .font(.callout)
                .padding(4)
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
