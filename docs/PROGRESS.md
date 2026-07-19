# v2 Redesign — Progress Tracker

Working doc for the `v2-redesign` branch. Update this file **every work session**:
check off tasks, append to the History log, and record decisions in
[DECISIONS.md](DECISIONS.md). Design details live in [DESIGN.md](DESIGN.md).

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

---

## Phase 0 — Setup ✅

- [x] Commit training-pool work on `main` (`8b82745`)
- [x] Create `v2-redesign` branch
- [x] DESIGN.md, PROGRESS.md, DECISIONS.md
- [~] ML model research (background) → fold into DESIGN.md §5
- [x] User picked UI direction: **A "Studio"** → DECISIONS.md D-003

## Phase 1 — Corrections Ledger (keystone)

- [ ] `Persistence/SessionStore.swift`: videoID hashing, ledger append, snapshot,
      materialize
- [ ] `CodableFrame` promoted from tests into app target; `frames.bin` cache write/read
- [ ] Wire `AppState` mutation points to emit events (`setPointReviewStatus`,
      `updatePointBoundary`, `updateTrimBoundary`, analysis completion, save-to-pool,
      export)
- [ ] Restore session on video open (snapshot → `VideoAnalysisResult`)
- [ ] Undo/redo (⌘Z/⇧⌘Z) via ledger replay
- [ ] `SessionStoreTests`: round-trip, replay, identity stability
- [ ] All existing tests green after `xcodebuild clean`

## Phase 2 — UI Shell Redesign

- [ ] Implement chosen option (pending D-003) as empty shell hosting existing views
- [ ] Migrate player + timeline into center pane
- [ ] Migrate point list into inspector
- [ ] Absorb Rm Stats into Export panel; training UI into Models panel
- [ ] Delete dead tab scaffolding

## Phase 3 — Review Affordances

- [ ] Add-missed-point (timeline button + shortcut; default span heuristic)
- [ ] Added points flow into scoring/export/training-clip extraction
- [ ] Review-state chips (auto/confirmed/edited/added/deleted)
- [ ] 👍/👎 rating capture → ledger

## Phase 4 — Highlight Scoring (heuristic)

- [ ] `HighlightScorer`: 6 features + percentile normalization + weighted sum
- [ ] Score badges + sort in point list; top-K slider
- [ ] Golden tests over 5 cached videos

## Phase 5 — Export Policies

- [ ] `ExportPlan` model; `VideoExporter.export(plan:points:)`
- [ ] Scoring reel + highlight reel + individual clips
- [ ] Per-reel summary (duration/size); remove dead `ExportConfig` paths

## Phase 6 — Model Lifecycle + Config Unification

- [ ] Versioned model registry (`models/<name>/vNNN/` + metadata + current pointer)
- [ ] Shadow eval: replay corrected sessions, precision/recall/boundary-MAE, gate
- [ ] Promote/revert UI in Models panel
- [ ] Move hardcoded `HybridSegmenter` constants into `AnalysisConfig` (tests pin
      behavior unchanged)
- [ ] `ShadowEvalTests`

## Phase 7 — Learned Ranker + Polish

- [ ] Tabular ranker from ratings (≥30) with gated rollout
- [ ] Score overlay on scoring reel (`AVVideoCompositionCoreAnimationTool`)
- [ ] Crossfade transition

## Phase 8 — ML Upgrades

- [ ] Per DESIGN.md §5 recommendations (pending research)

---

## History

| Date | What happened |
|---|---|
| 2026-07-18 | Reviewed codebase (pipeline + UI/feedback-loop audit). Identified gaps G1–G8. Committed training-pool refactor to `main` (`8b82745`). Created `v2-redesign`. Wrote DESIGN/PROGRESS/DECISIONS docs. Launched background research on badminton ML models (TrackNet successors, ShuttleSet/CoachAI, pose, audio, highlights). |
