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

## Phase 3 — Review Affordances ✅

- [x] Add-missed-point (timeline button + bare "A" shortcut; span heuristic:
      break's high-audio window ±1s padding within 3s of playhead, else ±4s,
      clamped to the break — `SegmentUtils.defaultAddedPointSpan`, 7 tests)
- [x] Added points flow into scoring/export/training-clip extraction (they are
      ordinary GamePoints materialized from `pointAdded`; timeline rally blocks
      now draw from active points so added ones render)
- [x] Review-state chips (auto/confirmed/edited/added/deleted) — derived from
      ledger effective corrections (`addedPointIDs`/`editedPointIDs`), not
      stored; rated points count as confirmed
- [x] 👍/👎 rating capture → ledger (`highlightRated`, audit-only/not undoable;
      re-tap clears via rating "none"; derived map restored with the session)

## Phase 4 — Highlight Scoring (heuristic) ✅

- [x] `HighlightScorer`: 6 features + percentile normalization + weighted sum
      (plus `HitDetector` per §5.1: trajectory descending→ascending direction
      changes fused with audio onsets — feeds hitCount/tempo)
- [x] Score badges + sort in point list (Time/Score toggle; score mode ranks
      flat across games); top-K slider (top-K rows get filled star)
- [x] Golden tests over 5 cached videos (top-3 start times pinned) + 6 unit
      tests over synthetic trajectories/audio

## Phase 5 — Export Policies ✅

- [x] `ExportPlan` model; `VideoExporter.run(jobs:)` (AppState builds the job
      list; passthrough when matching source format, re-encode fallback)
- [x] Scoring reel + highlight reel (`HighlightScorer.select`:
      topPercent/topMinutes/threshold, 4 tests) + individual clips
      (`<base>.clips/G<g>_point<nn>.mov`)
- [x] Per-reel summary (pre-export estimates from source bitrate + post-export
      actuals with show-in-Finder); removed dead `ExportConfig`/`ExportMode`

## Phase 6 — Model Lifecycle + Config Unification ✅

- [x] Versioned model registry (`models/<name>/vNNN/` + metadata.json +
      `current.json` pointer; legacy flat model migrates to promoted v001 —
      verified live)
- [x] Shadow eval: replay corrected sessions' cached frames through the
      pipeline; IoU≥0.5 matching → precision/recall/F1, boundary MAE,
      added-point recall; gate holds on F1 regression (ε 0.02) or added-point
      recall drop. NOTE: replay evaluates the segmentation over cached frames —
      candidate-vs-current audio scoring differences need audio re-extraction
      (deferred to Phase 8 with the vDSP onset upgrade)
- [x] Promote/revert UI in Models panel (version list with metrics + held-gate
      reason; one-click Promote / Revert to)
- [x] Move hardcoded `HybridSegmenter` constants into `AnalysisConfig` (19
      fields: blend weights, Otsu clamp, merge/roll constants, dip weights +
      sensitivity ladder; defaults identical — golden + segmentation suites pin
      behavior unchanged)
- [x] `ShadowEvalTests` (12 tests: IoU, matching, aggregation, gate, registry
      round-trip/promote/revert/migration)

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
| 2026-07-18 | **Phase 3 complete** (`0ff1912`). Add Point button in timeline footer (bare "A" shortcut) inserts an undoable `pointAdded` correction with high-audio-window default span. Review chips per point row derived from the ledger; 👍/👎 buttons record `highlightRated` events and survive session restore. 7 new span-heuristic tests; SegmentUtils + SessionStore suites green; build clean; UI render verified by screenshot (interactive flow needs a video analysis — not yet exercised). |
| 2026-07-19 | **Phase 4 complete** (`19b7b76`). New `HighlightScorer.swift`: `HitDetector` (trajectory vy direction-changes + audio-onset fusion) and 6-feature percentile-weighted scoring per DESIGN §3.4. AppState recomputes on every point mutation; Points panel gains star badges, Time/Score sort, top-K slider. Golden top-3 pinned for all 5 cached videos (e.g. IMG_8510: 6.6/686.8/501.2s). All suites green. New-file pbxproj registration done (explicit refs). |
| 2026-07-19 | **Phase 5 complete** (`3edc392`). ExportPlan/ExportOutput models, HighlightScorer.select policies, job-based VideoExporter with passthrough+fallback, rebuilt Export panel (reel toggles, selection slider, estimates, results). **Full E2E verified via UI automation on IMG_6155.rallies.mov**: import → analyze (11 pts) → chips/👍(confirmed chip)/score-sort/top-K → Add Point (added chip, renumber, rescore) → ⌘Z undo (rating survives) → dual-reel export (h264 passthrough, 65.1s + 22.0s, sizes shown). Known polish: point rows too cramped at min inspector width (chips/badges wrap). |
| 2026-07-19 | **Phase 6 complete** (`4a8e1c7`). ModelRegistry (vNNN dirs + current pointer, legacy migration verified live in app), ShadowEval engine + promotion gate, trainFromPool now train→register→shadow-eval→gate→promote/hold, Models panel version list w/ metrics + promote/revert. 19 shuttle-primary constants lifted into AnalysisConfig, defaults pinned by test suites (all green incl. goldens). Limitation noted: shadow replay can't yet re-score audio with a candidate model (needs audio re-extraction — Phase 8). |
