import Foundation
import CoreML
import CreateML

/// Personal highlight ranker (DESIGN §3.4 Phase B): a tabular regressor over
/// the six percentile features, trained from the user's 👍/👎 ratings across
/// all sessions. Replaces the heuristic's fixed weights, not its features.
enum HighlightRanker {

    static let modelName = "highlight_ranker"
    static let minimumRatings = 30
    static let targetColumn = "liked"

    struct RatedSample {
        var features: [Double]      // HighlightScorer.featureNames order
        var liked: Bool
    }

    enum RankerError: LocalizedError {
        case notEnoughRatings(Int)
        case trainingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughRatings(let count):
                return "Not enough ratings: \(count) of \(minimumRatings) needed. Keep rating points 👍/👎."
            case .trainingFailed(let message):
                return "Ranker training failed: \(message)"
            }
        }
    }

    // MARK: - Rating Pool (derived entirely from session ledgers)

    /// One sample per rated, non-deleted point across every analysis run of
    /// every session — taste data keeps its value across re-analyses.
    static func collectSamples(store: SessionStore) -> [RatedSample] {
        var samples: [RatedSample] = []
        for vid in store.allVideoIDs() {
            for run in store.runNumbers(forVideoID: vid) {
                guard let session = store.loadRun(videoID: vid, run: run),
                      !session.frames.isEmpty else { continue }

                // Latest rating per point; "none" clears. Ratings are audit
                // events, so read all of them (not just effective corrections).
                var ratings: [UUID: Bool] = [:]
                for event in session.events {
                    if case .highlightRated(let pointID, let raw) = event {
                        switch HighlightRating(rawValue: raw) {
                        case .up: ratings[pointID] = true
                        case .down: ratings[pointID] = false
                        case nil: ratings.removeValue(forKey: pointID)
                        }
                    }
                }
                guard !ratings.isEmpty else { continue }

                let effective = SessionMaterializer.effectiveCorrections(from: session.events)
                let points = SessionMaterializer.apply(events: effective, to: session.baseline.games)
                    .flatMap(\.points)
                    .filter { $0.reviewStatus != .deleted }
                let vectors = HighlightScorer.percentileFeatureVectors(
                    points: points,
                    frames: session.frames,
                    onsets: session.audioSignals?.onsets ?? []
                )

                for point in points {
                    guard let liked = ratings[point.id], let vector = vectors[point.id] else { continue }
                    samples.append(RatedSample(features: vector, liked: liked))
                }
            }
        }
        return samples
    }

    // MARK: - Training

    /// Train a linear regressor (liked = 1, disliked = 0) and compile it to
    /// `outputURL`. Returns the corpus concordance of the trained model.
    static func train(samples: [RatedSample], outputModelURL: URL) async throws -> Double {
        guard samples.count >= minimumRatings else {
            throw RankerError.notEnoughRatings(samples.count)
        }

        return try await Task.detached {
            var columns: [String: [Double]] = [targetColumn: samples.map { $0.liked ? 1.0 : 0.0 }]
            for (i, name) in HighlightScorer.featureNames.enumerated() {
                columns[name] = samples.map { $0.features[i] }
            }

            let table: MLDataTable
            let regressor: MLLinearRegressor
            do {
                table = try MLDataTable(dictionary: columns)
                regressor = try MLLinearRegressor(trainingData: table, targetColumn: targetColumn)
            } catch {
                throw RankerError.trainingFailed(error.localizedDescription)
            }

            let parentDir = outputModelURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let tempURL = parentDir.appendingPathComponent("highlight_ranker_temp.mlmodel")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                try regressor.write(to: tempURL)
                let compiled = try MLModel.compileModel(at: tempURL)
                try? FileManager.default.removeItem(at: outputModelURL)
                try FileManager.default.moveItem(at: compiled, to: outputModelURL)
            } catch {
                throw RankerError.trainingFailed(error.localizedDescription)
            }

            let model = try MLModel(contentsOf: outputModelURL)
            let scored = samples.map { (score: predict(model: model, features: $0.features) ?? 0.5, liked: $0.liked) }
            return concordance(of: scored) ?? 1.0
        }.value
    }

    // MARK: - Inference

    static func loadModel(at url: URL) -> MLModel? {
        try? MLModel(contentsOf: url)
    }

    /// Predicted "liked" value for one feature vector, clamped to [0, 1].
    static func predict(model: MLModel, features: [Double]) -> Double? {
        var dict: [String: Double] = [:]
        for (i, name) in HighlightScorer.featureNames.enumerated() where i < features.count {
            dict[name] = features[i]
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
              let output = try? model.prediction(from: provider),
              let value = output.featureValue(for: targetColumn)?.doubleValue else { return nil }
        return min(max(value, 0), 1)
    }

    // MARK: - Evaluation

    /// Pairwise concordance: over all (liked, disliked) pairs, the fraction
    /// where the liked point scores higher (ties count half). Nil when the
    /// ratings are all one class — no ranking signal to measure.
    static func concordance(of scored: [(score: Double, liked: Bool)]) -> Double? {
        let ups = scored.filter(\.liked).map(\.score)
        let downs = scored.filter { !$0.liked }.map(\.score)
        guard !ups.isEmpty, !downs.isEmpty else { return nil }

        var wins = 0.0
        for up in ups {
            for down in downs {
                if up > down { wins += 1 } else if up == down { wins += 0.5 }
            }
        }
        return wins / Double(ups.count * downs.count)
    }
}
