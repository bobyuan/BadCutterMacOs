import SwiftUI

struct ModelsTabView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Hit Detection Model")
                .font(.title2).bold()

            statusView

            actionButtons

            instructionsView

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        switch appState.hitModelStatus {
        case .notTrained:
            Label("Not Trained", systemImage: "circle")
                .foregroundStyle(.secondary)

        case .training(let progress):
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .trained(let accuracy, let clipCount):
            VStack(spacing: 4) {
                Label("Trained", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if clipCount > 0 {
                    Text(String(format: "%d clips, %.0f%% accuracy", clipCount, accuracy * 100))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Model loaded from previous session")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let error):
            VStack(spacing: 4) {
                Label("Training Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: - Actions

    private var canTrain: Bool {
        guard appState.currentAssetURL != nil, !appState.games.isEmpty else { return false }
        if case .training = appState.hitModelStatus { return false }
        return true
    }

    private var hasModel: Bool {
        if case .trained = appState.hitModelStatus { return true }
        return false
    }

    private var isTraining: Bool {
        if case .training = appState.hitModelStatus { return true }
        return false
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button("Train Hit Detector") {
                appState.trainHitDetector()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canTrain)

            if hasModel {
                Button("Delete Model") {
                    appState.deleteHitModel()
                }
                .buttonStyle(.bordered)
                .disabled(isTraining)
            }
        }

        if hasModel {
            Text("Re-analyze your video (Analysis tab) to use the trained model.")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    // MARK: - Instructions

    @ViewBuilder
    private var instructionsView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("How It Works")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: 1, text: "Analyze a video (Analysis tab)")
                    instructionRow(number: 2, text: "Review & correct points (Timeline tab)")
                    instructionRow(number: 3, text: "Train model (this tab)")
                    instructionRow(number: 4, text: "Re-analyze for better results")
                }

                Text("The model learns from your corrections to distinguish rally sounds from background noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .frame(maxWidth: 400)
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.callout)
                .bold()
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
        }
    }
}
