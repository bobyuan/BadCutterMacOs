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

## Phase 7 — Learned Ranker + Polish ✅

- [x] Tabular ranker from ratings (≥30) with gated rollout (`HighlightRanker`:
      pool from session ledgers, MLLinearRegressor over the shared percentile
      features, pairwise concordance metric, highlight_ranker registry + gate;
      promoted ranker replaces heuristic weights in `refreshHighlightScores`,
      Models panel section w/ rating count + versions). NOTE: not yet exercised
      with 30 real ratings — unit tests cover train/predict/concordance
- [x] Score overlay on scoring reel (`AVVideoCompositionCoreAnimationTool`;
      badge pre-rendered to CGImage — CATextLayer doesn't render in the export
      pipeline; timed per-point visibility; verified in exported frames)
- [x] Crossfade transition (A/B alternating tracks, 0.5s opacity + audio-mix
      ramps, fade capped at half the shortest segment; verified: reel duration
      shrank by exactly 10 fades and a boundary frame shows the blend)

## Phase 8 — ML Upgrades ✅

- [x] vDSP audio-onset hit timing (`AudioSignalExtractor.detectOnsets`: RMS
      envelope → rectified flux → adaptive threshold; fused into `HitDetector`
      in place of quantized audio edges; cached per session as `audio.json`)
- [x] Crowd-excitement signal (`SNClassifySoundRequest` .version1
      applause/cheering/crowd → cheer timeline → 90/10 blend into highlight
      scores, heuristic and ranker paths alike)
- [x] Goldens preserved (cached-frames replay passes no audio signals)
- [ ] Deferred (watch-list per §5.2): TrackNetV4/WASB/BST swaps; D-007
      candidate-audio shadow re-scoring; venue profiles (§3.6 step 2)

---

## Post-v2 — Feedback-Driven Adjustment ✅

- [x] 👎 reason menu (8 reasons; taste vs detection split per D-008)
- [x] `PointAdjuster` auto-fix engine (7 unit tests; refuses low-evidence fixes)
- [x] Tune UI: zoom-to-point, ghost boundaries, per-edge play/nudge/set-here,
      Undo/Done — all via ledger
- [x] Live-verified: decline path, auto-fix path (−10.4s start move), ⌘Z restore

## Backlog — identified 2026-07-20, not scheduled

- [ ] **Library persistence**: imported-video list is in-memory only — persist
      paths and restore on launch (sessions already auto-restore per video).
      Biggest daily-friction item.
- [ ] **Release build / stable install**: archive a Release build to
      /Applications so daily use isn't on Debug binaries from DerivedData
      (root cause of two "stale binary" confusions).
- [ ] **Session-storage housekeeping**: show per-video session/run disk usage;
      prune old runs (each keeps a frames cache ~0.2–1 MB forever by design).
- [ ] **Multi-video export**: apply the current ExportPlan to every analyzed
      video in the library in one pass.
- [ ] **Venue profiles (DESIGN §3.6 step 2)**: act on the Feedback Signals —
      named config overlays + one-click "apply suggested tuning".
- [ ] Watch-list ML swaps (DESIGN §5.2) — only if tracking failures appear.
- [ ] Ranker live activation — automatic at 30 ratings (user-driven, no code).

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
| 2026-07-19 | **Phase 7 complete** (`1ffe670`). HighlightRanker (ledger-derived rating pool → MLLinearRegressor → concordance-gated registry rollout; heuristic fallback), score overlay + crossfade in a new composed VideoExporter path (A/B tracks, audio ramps). Debug win: CATextLayer renders blank inside AVVideoCompositionCoreAnimationTool — replaced with pre-rendered CGImage badge. E2E on restored session: 60.5s reel (10 fades applied), "1:0" badge at 2s, mid-blend + "2:0" at 5.45s. Ranker awaits 30 real ratings for live exercise. |
| 2026-07-19 | **Phase 8 complete** (`64d7b41`) — **all 8 phases done**. AudioSignalExtractor: vDSP onsets + built-in-classifier cheer timeline, one audio pass per analysis, session-cached. HitDetector fuses precise onsets; cheer blends 90/10 into scores. Verified live on fresh 22s analysis (72 onsets, 43 cheer samples, quiet-gym max 0.079). Inspector widened — point rows finally fit on one line. Also discovered: user analyzed IMG_8510 + rated 2 points overnight in the stale app instance — ledger captured everything (rating pool now 3 across 2 videos). Batch "Analyze Selected" skips already-done videos (restored sessions count as done) — a force-reanalyze affordance may be wanted later. |
| 2026-07-19 | **Feedback-driven adjustment** (`ad78bb2`, on main post-merge). 👎 → reason menu; PointAdjuster auto-fixes boundaries from presence/motion/onsets; tune bar with ghost boundaries; D-008 keeps detection complaints out of the ranker pool. Live-verified both the decline path and a −10.4s auto-fix + undo. |
| 2026-07-20 | **Tune-handle + scrub + feedback-escalation fixes** (`05ad3e9`). Orange boundary handles on the tuned point drag past the current boundary (neighbor-clamped); playhead scrub knob + drag-to-scrub on the trim strip; repeated 👎 reasons always act — fixed fallback nudge when the signal declines, and flush-neighbor merge (absorb next/previous point) for ends-too-early / starts-too-late. Live-verified flush merge + double-undo. |
| 2026-07-20 | **Analysis history** (`fb8f9ac`). Versioned runs (runs/rNNN + current pointer, run-tagged ledger, auto-migration of flat sessions), History inspector tab (per-run cards + full adjustment audit trail + local-storage guarantee), version pill w/ switcher + orange "(older)" state, re-analyze confirmation ("keep history" in the button). Ranker pool spans all runs; shadow corpus uses current run (D-009). Live-verified: migration, re-analysis → r002 with r001 untouched, switch-back restoring hand-tuned state. |

## Review-Loop Upgrades (DESIGN §8)

- [x] 8.1 Keyboard review mode (j/k/↑↓/space/u/n/x via NSEvent monitor —
      SwiftUI bare-key shortcuts don't fire from hidden views; live-verified j/j/u)
- [x] 8.2 Auto-audition after feedback fixes (plays ±1.5s around the changed
      boundary via TimelineController.playWindow)
- [x] 8.3 Automatic ranker training (first at 30 ratings, then every +10;
      triggers on video switch / Models panel; concordance gate unchanged;
      first promotion announces "Scores now ranked by your taste". Awaits 30
      real ratings for live exercise)
- [x] 8.4 Context menus (row: Play/👍/👎/reasons/Delete; timeline gap:
      "Add point in this gap" via the add-point span heuristic)
- [x] 8.5 Batch verdicts (⌘-click toggles membership, orange row tint,
      batch bar with Delete/👍/👎/Clear when ≥2 selected)
- [x] 8.6 Feedback Signals section in Models (per-reason tallies + venue-tuning
      hint when a reason hits 3×) + one-time save-for-training nudge at 3
      corrections on an unpooled video
| 2026-07-20 | **Review-loop upgrades 8.1–8.3** (`e1ab268`). Keyboard review mode (NSEvent monitor — hidden-button keyboardShortcut approach failed for bare keys), auto-audition after feedback fixes, debounced+gated+announced ranker auto-training. Live-verified j/j/u full loop with grabbers following. 8.4–8.6 tracked as follow-ups. |
| 2026-07-20 | **Review-loop upgrades 8.4–8.6 complete — §8 done** (`45eb087`). Row context menus (Play/rate/reasons/delete), gap right-click add-point, ⌘-click batch verdicts with batch bar, Feedback Signals aggregation in Models (verified live: "3× ends too early → post-roll may be too tight"), save-for-training nudge at 3 corrections. Context menu + batch click need a real mouse (AX can't synthesize them) — code is standard SwiftUI, build-verified. |
| 2026-07-20 | **Overlap fixes + ripple drag** (`fde3986`). Reported bug: a boundary edit left #16 fully inside #17 and out of order. Fixes: (1) updatePointBoundary now clamps against active neighbors in every path; (2) points re-sort + renumber after boundary commits AND in the materializer (restores repair historical out-of-order data); (3) red ⚠️ badge on overlapping rows with repair hint; (4) per user request, dragging an orange grabber into the next/previous play now PUSHES that play's boundary along (ripple, min 0.5s kept, pushed neighbor ledger-committed on release) instead of stopping. |
| 2026-07-20 | **Freeze fix** (`0c3b3ed`). Loading a second video could hang the UI: the §8.3 auto-train trigger ran a detached ratings scan concurrently with the main-thread session load, racing SessionStore's unsynchronized caches (Swift Dictionary corruption can spin/hang). Fixed: NSLock around videoIDCache/nextSeqCache, and the auto-train check moved to AFTER the video switch completes. |
| 2026-07-20 | **Freeze fix live-verified** (two-video load + keyboard interaction responsive; resort + overlap badges confirmed on real 32-point data) · **History label polish**: history rows now resolve point labels against each run's own materialized points ("Moved #16 (3:34) end +8.1s" instead of "a point" for non-current runs). |
| 2026-07-20 | **D-007 resolved** (`afc85fe`). Shadow eval re-scores session audio through the evaluated hit model (HitClassifier over meta.filePath, audio-only), remaps windows onto cached frames (ShadowEval.remapAudioScores, unit-tested), replays the pipeline; candidate vs current evaluated like-for-like with stored-metrics fallback. filePath backfills on session open. |
| 2026-07-20 | **Zoom-on-select** (`7323a78`). Clicking a play (or j/k stepping) now zooms the timeline to that play ±8s — same framing the tune mode uses — instead of scrolling at 1x where the play was a sliver. Minimap/zoom-out for overview unchanged. |
| 2026-07-20 | **Re-segment extended spans** (`38f2c1e`). User-reported: "starts too late" pulling a play back to the previous play's end can swallow a whole second rally + its pause. Automatic extensions (startsTooLate/endsTooEarly walks, fallback nudges, flush merges) now re-run local detection over the new span (`PointAdjuster.internalBreaks`, unit-tested) and split it at internal breaks via ledger events (undo walks back). Manual grabber extensions don't auto-split — they surface a "looks like N rallies — split it" suggestion instead. |
| 2026-07-20 | **Adaptive zoom-on-select**. Selection framing is now proportional: the play fills ~70% of the strip regardless of duration (margin = max(2s, 20% of duration), tune-mode framing matched incl. ghosts) — a 3s play gets the same drag precision as a 30s one. |
| 2026-07-20 | **Split at playhead**. Right-click a play's green block on the trim strip → "Split play at playhead": splits the play containing the playhead into two flush points exactly there (guard: ≥0.5s each side; ledger boundaryChanged + pointAdded, double-undo reverts). Complements the automatic dip-based split. |
| 2026-07-20 | **Split-play mode**. Right-click a play → "Split play here…" enters an explicit mode: the playhead knob turns orange and follows the mouse (video scrubs live), a scissors tip reads "Click to split · Esc cancels"; click confirms the split at that exact moment, Esc (or the status bar) cancels. Replaces the one-shot split-at-playhead menu item. |
| 2026-07-20 | **Score accuracy after corrections**. Reported: scores wrong (3:0 vs 2:1) after splits/manual adjustments — serve sides (which decide the winning party) were only detected at analysis time, so new points had none and moved starts kept stale frames. Now: incremental serve re-detection (debounced 0.8s) for points with missing sides or moved starts, triggered on start-edge commits, rematerialization (splits/adds/undo), and session load; results persist into the run baseline. |
| 2026-07-20 | **Manual serve-side override**. Right-click a point → "Score wrong — serve side" → pin Left/Right serves (✓ marks the current effective side). Recorded as a `serveSideOverridden` ledger event: wins over automatic detection permanently (re-detection skips pinned points), score chain recomputes immediately, shows in History. Build-verified; suite run deferred (user's app instance was blocking the test host). |
| 2026-07-20 | **Axis-aware serve labels**. The detector already auto-picks the frame axis that best separates the parties (x vs y variance) — but labels stayed "left/right" even for end-of-court cameras where the split is near|far. Now the axis is surfaced (`ServeDetector.Axis`, persisted in the baseline) and every label adapts: side-view videos say "Left/Right side serves", end-view say "Near/Far side serves" — in the right-click override menu, status messages, and History rows. |
| 2026-07-20 | **Score rule verified + corrected** (user audit). computeScores encoded winner-of-N = server-of-N+1 only via the serve *transition*, so one misdetected side corrupted two points and unknown-current cases fell to guessing. Rewritten to the direct rule: winner of N = the side serving N+1 (misdetection now hits one point; unknown current serve no longer matters). Two unit tests pin the chain incl. the unknown-current case; suite run deferred while the app is in use. |
| 2026-07-20 | **Deferred suites cleared** (all green after app closed; fixed tuple assertions in new score tests) · **Recalculate score from here**: right-click a play → clears detected serve sides from that play onward (pinned overrides survive), re-detects them incrementally (frame reads only — no re-analysis), and recomputes the score chain. |
| 2026-07-20 | **A-anchor unified** (user audit: "always display A:B, A = first server"). computeScores previously anchored A to the earliest point with a *detected* side — when play #1's detection failed, A silently re-anchored to a later server (possibly the other party), and the menu labels used yet another fallback, so columns and labels could contradict. Now one anchor: the game's first active play's effective side (pin-aware), passed explicitly into computeScores and shared by the A/B menu labels + tested. Pinning play #1's serve now definitively defines A. |
| 2026-07-20 | **Full-context ML serve re-detection**. "Recalculate score from here" (and every incremental re-detection) now runs the vision model over ALL active plays — the side classifier splits around the centroid distribution's median, so detecting only a small/one-sided subset mis-split it. Fresh detections apply only to the recalculated plays (manual pins untouched), the axis updates from the full set, status messages narrate the ML pass, and results persist to the run baseline. |
| 2026-07-20 | **Winner-based score correction** (user: "I just want to say who won the point"). The right-click menu is now "Score wrong — who won this play?" → "Side A won / Side B won" with a native checkmark on the currently-scored winner (derived from the score delta vs the previous play). Internally: winner(N) = server(N+1), so mid-game corrections pin the next play's serve; the match's final play gets its own `pointWinnerOverridden` ledger event + computeScores lastPointWinner param. Serve-side machinery remains underneath (pins, ML re-detection). |
| 2026-07-20 | **Score rules engine + reconciliation + game separator** (user found 23:9 — impossible). (1) `ScoreValidator`: badminton rules (21 win-by-2, deuce to 30) flag illegal chains with a red ⚠️ + explanation on the game header at the first offending play. (2) "Fix score…": user enters the TRUE final score; the app re-analyzes serve confidence and flips only the least-confident winner calls (pinned plays untouchable), listing the flipped plays — each undoable. (3) Game separator: right-click → "Start new game from this play…" (confirmed) → ledger `gameSplitInserted` correction; materializer splits games, fresh 0:0 + per-game Side A; ⌘Z merges back. (4) A/B winner chip on every row. Tests written for validator/flips/split; suite run deferred (app open). |
| 2026-07-20 | **A/B legend + court photo, and corrections can no longer touch earlier plays** (user: "who is A? and correcting one play impacted the former play"). (1) Each game header now shows "A = far side · B = near side" (axis-aware) with a 📷 button → popover of a real video frame from that game's first serve with A/B badges overlaid on the two court halves — you see YOUR players labeled. (2) Root cause of the former-play corruption: when play #1's serve was undetected, A anchored to the earliest *known* serve, so pinning a later play could re-anchor A/B and flip every earlier row. Now any manual correction first freezes the anchor (pins play #1's side to the current belief, recorded in History). (3) "Recalculate from here" no longer clears the selected play's own serve — that serve encodes the FORMER play's winner; only strictly-later plays are re-detected. |
| 2026-07-20 | **Real player figures in the A/B legend** (user ask). `LegendFigureDetector` runs Vision's `VNDetectHumanRectanglesRequest` on frames around the game's first serve (tries serve+0.5s, mid-play, serve+2s; keeps the frame showing the most players, preferring both sides). Each detected player is assigned A/B by their court half along the serve axis. Legend popover now shows: the frame with each player boxed + lettered in side color, and cropped figure thumbnails grouped under A (blue) and B (orange). Tiny circular player chips also appear inline in the game header next to the legend caption (auto-loaded on appear, cached by first-point ID so re-materialization doesn't re-run Vision). Falls back to half-labels when no players are detected. |
| 2026-07-21 | **Backward ripple eliminated for score corrections** (user: corrected play #2, play #1's point reversed). Three leak paths closed: (1) `pinDisplayedWinners(before:)` — correcting a play (winner menu or "Recalculate from here") first records the currently-displayed winner of every EARLIER play as durable overrides (guessed serves pinned, game-final plays get explicit winner events); pins equal what's on screen, so nothing visibly moves — the rows above a correction are frozen against the correction itself and against later background re-detection filling in missing serves. (2) `overrideWinner` now finds the "next play" within the same game — correcting a game's last play previously pinned the NEXT game's first serve, re-anchoring that game's A/B. (3) `computeScores`: an explicit final-play winner override now beats `nextGameFirstServe` (that serve can be an anchor pin, not evidence). |
| 2026-07-21 | **Anchor + prefix made fully durable** (user: 1:0, 2:0 → corrected play 2 → 0:1, 0:2 — whole column flip). The remaining hole: `freezeAnchorIfNeeded` and `pinDisplayedWinners` skipped plays whose serve was *detected* — but detected sides can be overwritten by later re-detection (dirty plays after boundary drags), flipping the game's first side re-labels every A/B column. Now any correction pins the first play's side and every prefix serve regardless of detected/missing (pins equal displayed values — nothing visibly moves). Regression tests added: exact user chain (1:0,2:0 → correct play2=B → 1:0,1:1) + explicit final-play winner beats nextGameFirstServe. Suite run still deferred (app open). |
| 2026-07-21 | **"Already scored that way" feedback + Swap A↔B** (user: clicked "Side B won" on play 2, nothing changed — the app already scored play 2 for B; the flipped-columns fallout from older builds left play 1 as the wrong row). (1) `overrideWinner` selecting the current belief is now an explicit no-op with a status message pointing at the real remedies (correct the wrong row, or swap sides) — previously it silently recorded prefix pins. (2) `swapSides(for:)`: one click re-anchors a game whose A/B labels are reversed (pins first play's serve to the opposite side; all letters and both columns swap; physical winners unchanged). Buttons: ⇄ icon in the game header next to the legend + "Wrong way around? Swap A ↔ B" inside the legend popover under the player figures. |
| 2026-07-21 | **docs/SCORING.md** — score calculation/adjustment design doc drafted (user ask) + gap audit. Key finding: the median split in ServeDetector is structurally wrong for rally scoring (winner keeps serving → serve sides are unbalanced → median forces ~50/50 → dominant server's plays mechanically misclassified). 10 gaps logged (G1–G10) with severities; redesign specifies shuttle-first classification from cached TrackNet positions, largest-gap cluster split, serve-moment window anchoring via audio onsets, sequence inference (Viterbi with terminal-rule pruning), persisted axis, provenance badges. |
| 2026-07-21 | **Winner-detection diagnostics** (user ask: detailed logs for troubleshooting; they'll paste them back for analysis). (1) `/tmp/serve_detection_log.txt` — written on every detection pass: per-play motion centroid, axis + variances, median split + dead zone, axis value, margin, resulting side, frame-grab failures (marked as G3 pollution). (2) `/tmp/score_detection_log.txt` — written on every score computation via new `computeScoresWithTrace`: per game the A-anchor + source (pinned/detected/fallback) + rules violations; per play the serve provenance (PINNED/detected/missing), the exact winner evidence ("next play (#7) served by left", "GUESS (assumed leader won)", "explicit final-play override"), and the running score. SCORING.md §10 documents both. |
| 2026-07-21 | **Correction audit log + all diagnostics append-only** (user: log corrections so model judgment vs actual can be compared; never overwrite calculation logs). New `/tmp/score_corrections_log.txt` (append-only): every winner correction captures the model's belief at that moment (trace + detection margin of the deciding serve), the user's truth, and what was recorded; confirmations (no-op clicks) logged as model-was-right samples; Swap A↔B and Fix-score reconciliations (per-flip margins) included. `serveMargins` now retained in AppState (both detection paths upgraded to `detectServesWithConfidence`) and shown in provenance (`left[detected m=0.0031]`). Score + serve logs converted to append-only timestamped run sections. |
| 2026-07-21 | **Score transition display** (user: single after-score was confusing; wants before AND after per play). Each row now shows `0:0 → 1:0`: the entering score in dim tertiary, an arrow, and the resulting score with the winner's incremented number bolded in their side's color (A blue / B orange) — the score's walk down the list and each play's taker are visible at a glance. `AppState.scoreBefore(of:)` (previous active play's score; 0:0 for a game's first play). |
| 2026-07-21 | **Serve/score state persisted on the fly** (user: quitting at any stage must keep the scores). Corrections were already instant (ledger appends per event); the gap was detected serve sides — written only when a re-detection pass *completed*, so quitting mid-pass (or after recalc-from-here cleared sides) left stale disk state and relaunch could re-detect different scores. Now `persistServeState()` writes sides+axis+margins into the run baseline at every mutation: after each re-detection apply, immediately after recalc clears sides, and on full detection. `SessionBaseline.serveMargins` added (optional, backward-compatible) and restored on load — provenance margins survive relaunch. |
