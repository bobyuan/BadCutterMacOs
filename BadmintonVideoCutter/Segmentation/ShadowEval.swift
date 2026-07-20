import Foundation

// MARK: - Metrics

/// Aggregated shadow-evaluation result (DESIGN §3.5): how well a pipeline
/// reproduces the user's corrected sessions.
struct ShadowEvalMetrics: Codable, Equatable {
    var truePositives = 0
    var falsePositives = 0
    var falseNegatives = 0
    /// Mean of per-matched-point boundary error (average of |Δstart| and |Δend|), seconds.
    var boundaryMAE: Double = 0
    /// User-added points — the detections the previous model missed.
    var addedPointsTotal = 0
    var addedPointsFound = 0
    var sessionCount = 0

    var precision: Double {
        let denom = truePositives + falsePositives
        return denom == 0 ? 0 : Double(truePositives) / Double(denom)
    }
    var recall: Double {
        let denom = truePositives + falseNegatives
        return denom == 0 ? 0 : Double(truePositives) / Double(denom)
    }
    var f1: Double {
        let p = precision, r = recall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }
    var addedPointRecall: Double {
        addedPointsTotal == 0 ? 1 : Double(addedPointsFound) / Double(addedPointsTotal)
    }
}

// MARK: - Evaluation

enum ShadowEval {

    /// One session's comparison of predicted rally segments against the
    /// user-corrected ground truth.
    struct SessionResult {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var boundaryErrors: [Double] = []
        var addedPointsTotal = 0
        var addedPointsFound = 0
    }

    /// Intersection-over-union of two time ranges.
    static func iou(_ a: TimeSegment, _ b: TimeSegment) -> Double {
        let intersection = max(0, min(a.end, b.end) - max(a.start, b.start))
        guard intersection > 0 else { return 0 }
        let union = (a.end - a.start) + (b.end - b.start) - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Greedy IoU matching of predicted rally segments to active ground-truth
    /// points (best IoU first; each side matched at most once).
    static func evaluate(
        predicted: [TimeSegment],
        groundTruth: [GamePoint],
        addedPointIDs: Set<UUID>,
        iouThreshold: Double = 0.5
    ) -> SessionResult {
        let predictions = predicted.filter { $0.label == .rally && $0.end > $0.start }
        let truth = groundTruth.filter { $0.reviewStatus != .deleted }

        var pairs: [(iou: Double, p: Int, t: Int)] = []
        for (pi, p) in predictions.enumerated() {
            for (ti, t) in truth.enumerated() {
                let overlap = iou(p, t.rallySegment)
                if overlap >= iouThreshold {
                    pairs.append((overlap, pi, ti))
                }
            }
        }
        pairs.sort { $0.iou > $1.iou }

        var matchedP = Set<Int>()
        var matchedT = Set<Int>()
        var result = SessionResult()
        for pair in pairs where !matchedP.contains(pair.p) && !matchedT.contains(pair.t) {
            matchedP.insert(pair.p)
            matchedT.insert(pair.t)
            let p = predictions[pair.p]
            let t = truth[pair.t]
            result.boundaryErrors.append((abs(p.start - t.start) + abs(p.end - t.end)) / 2)
        }

        result.truePositives = matchedP.count
        result.falsePositives = predictions.count - matchedP.count
        result.falseNegatives = truth.count - matchedT.count
        result.addedPointsTotal = truth.filter { addedPointIDs.contains($0.id) }.count
        result.addedPointsFound = truth.enumerated()
            .filter { matchedT.contains($0.offset) && addedPointIDs.contains($0.element.id) }
            .count
        return result
    }

    static func aggregate(_ sessions: [SessionResult]) -> ShadowEvalMetrics {
        var metrics = ShadowEvalMetrics()
        var allErrors: [Double] = []
        for s in sessions {
            metrics.truePositives += s.truePositives
            metrics.falsePositives += s.falsePositives
            metrics.falseNegatives += s.falseNegatives
            metrics.addedPointsTotal += s.addedPointsTotal
            metrics.addedPointsFound += s.addedPointsFound
            allErrors.append(contentsOf: s.boundaryErrors)
        }
        metrics.sessionCount = sessions.count
        metrics.boundaryMAE = allErrors.isEmpty ? 0 : allErrors.reduce(0, +) / Double(allErrors.count)
        return metrics
    }

    // MARK: - Promotion Gate

    struct GateDecision: Codable, Equatable {
        var promote: Bool
        var reason: String
    }

    /// Promote only if F1 does not regress beyond epsilon and added-point
    /// recall does not regress (DESIGN §3.5). No current metrics (first
    /// version, or empty corpus) → promote.
    static func gate(
        candidate: ShadowEvalMetrics,
        current: ShadowEvalMetrics?,
        epsilon: Double = 0.02
    ) -> GateDecision {
        guard let current, current.sessionCount > 0 else {
            return GateDecision(promote: true, reason: "No baseline to compare — promoted.")
        }
        guard candidate.sessionCount > 0 else {
            return GateDecision(promote: true, reason: "No corrected sessions to evaluate — promoted.")
        }
        if candidate.f1 < current.f1 - epsilon {
            return GateDecision(
                promote: false,
                reason: String(format: "F1 regressed: %.3f vs current %.3f (ε %.2f).", candidate.f1, current.f1, epsilon)
            )
        }
        if candidate.addedPointRecall < current.addedPointRecall {
            return GateDecision(
                promote: false,
                reason: String(format: "Added-point recall regressed: %.0f%% vs %.0f%%.",
                               candidate.addedPointRecall * 100, current.addedPointRecall * 100)
            )
        }
        return GateDecision(
            promote: true,
            reason: String(format: "F1 %.3f (current %.3f), added-point recall %.0f%%.",
                           candidate.f1, current.f1, candidate.addedPointRecall * 100)
        )
    }
}

// MARK: - Corpus Replay

/// Replays every corrected session's cached frames through the segmentation
/// pipeline and scores the output against the user's corrected points.
/// Cheap (no video decode) — the regression corpus from DESIGN §3.1.
enum ShadowEvaluator {

    /// Sessions eligible for evaluation: each video's CURRENT run (the user's
    /// authoritative version) with at least one effective correction.
    static func evaluateCorpus(
        store: SessionStore,
        config: AnalysisConfig
    ) -> ShadowEvalMetrics {
        var results: [ShadowEval.SessionResult] = []
        for vid in store.allVideoIDs() {
            guard let run = store.currentRun(forVideoID: vid),
                  let session = store.loadRun(videoID: vid, run: run),
                  !session.frames.isEmpty else { continue }

            let effective = SessionMaterializer.effectiveCorrections(from: session.events)
            guard !effective.isEmpty else { continue }
            let truth = SessionMaterializer.apply(events: effective, to: session.baseline.games)
                .flatMap(\.points)
            var added = Set<UUID>()
            for event in effective {
                if case .pointAdded(let pointID, _, _) = event { added.insert(pointID) }
            }

            let predicted = runPipeline(frames: session.frames, config: config)
            results.append(ShadowEval.evaluate(predicted: predicted, groundTruth: truth, addedPointIDs: added))
        }
        return ShadowEval.aggregate(results)
    }

    /// The same pipeline AppState runs after feature extraction.
    static func runPipeline(frames: [FeatureFrame], config: AnalysisConfig) -> [TimeSegment] {
        let classifier = HybridSegmenter()
        let raw = classifier.classify(frames: frames, config: config)
        let processed = classifier.postProcess(segments: raw, frames: frames, config: config)
        let refined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
        return SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(refined), maxGap: 0.5)
    }
}
