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
- [x] ML model research → DESIGN.md §5 (keep TrackNetV3; adopt trajectory hit
      detection + audio onset upgrade + cheer signal; watch BST/RTMPose)
- [x] User picked UI direction: **A "Studio"** → DECISIONS.md D-003

## Phase 1 — Corrections Ledger (keystone) ✅

- [x] `Persistence/SessionModels.swift` (events, baseline, materializer) +
      `Persistence/SessionStore.swift` (videoID hashing, ledger append, load)
- [x] `CodableFrame` promoted from tests into app target; `frames.json` cache
      (JSON instead of .bin — matches TestData pattern, fast enough)
- [x] Wire `AppState` mutation points to emit events (`setPointReviewStatus`,
      boundary-drag commit via new `commitPointBoundary`, analysis completion,
      save-to-pool, export). Trim drags recorded via the adjacent *point*
      boundary only (trim IDs are regenerated on every derive → unstable; see
      D-006)
- [x] Restore session on video open (baseline + event replay + cached frames)
- [x] Undo/redo (⌘Z/⇧⌘Z) as ledger events (`undo`/`redo` are themselves
      appended — the ledger stays append-only)
- [x] `SessionStoreTests` (8 tests): identity stability, materialize,
      undo/redo semantics, pointAdded insert/renumber, ledger + baseline
      round-trips
- [x] All existing tests green after `xcodebuild clean` (HybridSegmenter,
      SegmentUtils, TrajectoryAnalyzer)

## Phase 2 — UI Shell Redesign ✅

- [x] Implement chosen option (Option A "Studio" per D-003): `StudioView`
      three-pane HSplitView + status bar; calibration presented as a sheet
- [x] Migrate player + timeline into center pane (`PlayerTimelinePane`, renamed
      from TimelineTabView; shared `TimelineController` for
      playhead/viewport/selection)
- [x] Migrate point list into inspector (`InspectorPane` Points section)
- [x] Absorb Rm Stats into Export panel; training UI into Models panel
      (Rm Stats histograms dropped — summary stats only)
- [x] Delete dead tab scaffolding (VideosTabView, ExportTabView,
      RemovalStatsTabView, TimelineViewPlaceholder, ContentViewModel)

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
| 2026-07-18 | ML research completed → DESIGN.md §5: TrackNetV3 stays (open SOTA); adopt trajectory-based hit detection (Sensors 2024, F1 90.5 fused) + vDSP audio onsets + SNClassifySoundRequest cheer signal; noted competitor RallyCut. User picked UI Option A "Studio". Started Phase 1 (corrections ledger). |
| 2026-07-18 | **Phase 1 complete.** SessionStore + SessionModels (append-only ledger.jsonl, baseline.json, frames.json, meta.json per content-hashed videoID). AppState wired: events on delete/restore/boundary-commit/pool-save/export; session auto-restores on video open; ⌘Z/⇧⌘Z undo-redo via event replay. Drag handles in TimelineTabView now commit net boundary change on release. 8 new tests + existing suites green. |
| 2026-07-18 | **Phase 2 complete.** Studio layout replaces 4 tabs: single window with LibraryPane / PlayerTimelinePane / InspectorPane (Points, Export, Models) in an HSplitView, status bar, calibration sheet. New `TimelineController` shares playhead/viewport/selection across panes. Deleted dead tab views + ContentViewModel. Rm Stats histograms dropped (summary only). Build clean, SessionStore + SegmentUtils tests pass, app launches. Commit delayed to next session by terminal TCC permission loss (`30a9dc3`). |
