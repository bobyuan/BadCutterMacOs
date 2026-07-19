# Badminton Video Cutter v2 — Design Document

Status: **draft — under review**
Branch: `v2-redesign`
Companion docs: [PROGRESS.md](PROGRESS.md) (task tracking + history), [DECISIONS.md](DECISIONS.md) (decision log)

---

## 1. Vision

An AI-assisted badminton video editor that:

1. **Detects** every rally automatically (shuttle tracking + audio + motion).
2. **Learns from the user** — every correction (delete, add, boundary drag, 👍/👎) becomes
   training signal, Tesla-FSD style: *intervention → labeled data → shadow evaluation →
   gated model rollout → user can always override and revert*.
3. **Exports by policy, not mode** — "scoring reel" and "highlight reel" are selection
   policies over one analysis, independently toggleable, not separate pipelines.
4. Presents a **simple, elegant interface**: one window, obvious flow, advanced power
   behind progressive disclosure.

### The pipeline reframe

```
detect rallies → structure into games/points → rank each rally → select → render
   (exists)            (exists)                  (NEW)           (NEW)   (rework)
```

Scoring reel = select *all active points*. Highlight reel = select *top-K by highlight
score*. Individual clips = render policy. All combinations valid in one export pass.

---

## 2. Current architecture (baseline, commit `8b82745`)

```
BasicFeatureExtractor ──> FeatureFrame[] (motion, audio, shuttle pos/flight @ ~5fps)
      │  TrackNetV3 (CoreML)  +  hit_classifier (MLSoundClassifier, optional)
      ▼
HybridSegmenter.classify/postProcess   (Otsu threshold, shuttle-primary blend,
      │                                 iterative long-rally splitting)
      ▼
TrajectoryAnalyzer.refineSegments      (shuttle-gap validation, 3-signal scoring)
      ▼
GameDetector → GamePoint/Game          ServeDetector → serve sides + PointScore
      ▼
PointListView review (delete/restore, boundary drag) → "Save for Training"
      ▼
Training pool (1s WAV clips, manifest.json) → trainFromPool() → hit_classifier.mlmodelc
      ▼
VideoExporter.exportRallyOnly          (AVMutableComposition concat, hard cuts)
```

### Known gaps this design addresses

| # | Gap | Impact |
|---|-----|--------|
| G1 | Review work (deletions, boundary edits) lives only in memory; lost on quit | Blocks all learning; wastes user labor |
| G2 | Can delete a false-positive point but cannot **add** a missed rally | Training data biased; model can only get *less* sensitive |
| G3 | `ExportConfig` (modes, transitions, format) is UI-only; exporter ignores it | Export options are decorative |
| G4 | Boundary drags discarded — precise supervision thrown away | Lost training signal |
| G5 | Shuttle-primary constants hardcoded in `HybridSegmenter` (blend 0.40/0.30/0.20/0.10, Otsu clamps, 15s split) | Presets/learning can't tune the main path |
| G6 | `trainFromPool` overwrites `hit_classifier.mlmodelc`; no eval, no rollback | One bad retrain silently degrades everything |
| G7 | No highlight concept anywhere | Can't ship "highlights only" |
| G8 | No undo; no persistence of analysis results | UX + trust |

---

## 3. Component designs

### 3.1 Corrections Ledger (keystone — everything depends on it)

**What:** a per-video, append-only event log + state snapshot, persisted immediately on
every user action and every analysis run.

**Where:** `~/Library/Application Support/BadmintonVideoCutter/sessions/<videoID>/`

```
sessions/<videoID>/
  ledger.jsonl          # append-only events, one JSON object per line
  snapshot.json         # latest materialized state (fast load; rebuildable from ledger)
  frames.bin            # cached FeatureFrame[] from last analysis (enables replay/shadow eval)
  meta.json             # filename, duration, file size, first-64KB hash, last opened
```

**Video identity (`videoID`):** `SHA256(first 64KB + fileSize + duration)` — stable across
renames/moves, cheap to compute.

**Event schema (`ledger.jsonl`):**

```json
{"seq": 17, "ts": "2026-07-18T21:04:11Z", "type": "pointDeleted",   "pointID": "g1p12"}
{"seq": 18, "ts": "...", "type": "boundaryChanged", "pointID": "g1p13", "edge": "end", "from": 45.2, "to": 47.1}
{"seq": 19, "ts": "...", "type": "pointAdded",      "start": 301.5, "end": 309.0}
{"seq": 20, "ts": "...", "type": "highlightRated",  "pointID": "g2p03", "rating": "up"}
{"seq": 21, "ts": "...", "type": "analysisRun",     "configHash": "…", "hitModel": "v003", "pointCount": 42}
{"seq": 22, "ts": "...", "type": "savedToPool",     "rallyClips": 38, "backgroundClips": 51}
{"seq": 23, "ts": "...", "type": "exported",        "policies": ["scoring"], "output": "IMG_6155.rallies.mov"}
```

Event types (v1): `analysisRun`, `pointDeleted`, `pointRestored`, `pointAdded`,
`boundaryChanged`, `trimBoundaryChanged`, `highlightRated`, `savedToPool`, `exported`.

**What the ledger buys us (each for free once it exists):**
- **Persistence** — reopen a video, restore full review state (G1, G8).
- **Undo/redo** — walk `seq` backwards/forwards (G8).
- **Training labels** — deletions, additions, and boundary edits are ground truth (G2, G4).
- **Regression corpus** — every corrected video + its cached `frames.bin` = a shadow-eval
  test case (G6). Same pattern as `TestData/` cached frames (0.07s replay vs 17min extract).
- **History** — the app can show "what happened to this video" chronologically.

**Implementation notes:**
- New `Persistence/SessionStore.swift`: `appendEvent(_:for:)`, `loadSession(for:)`,
  `materialize(events:) -> VideoAnalysisResult`. `AppState` calls it from
  `setPointReviewStatus`, `updatePointBoundary`, `updateTrimBoundary`, analysis completion.
- `frames.bin`: reuse the `CodableFrame` bridge from `TrainingPoolTests.swift:191-216`,
  but binary (PropertyList or simple packed floats) — 16.5k frames ≈ a few MB max.
- Snapshot written debounced (e.g. 1s after last event); ledger appended synchronously.

### 3.2 Add-missed-point + review affordances (fixes label asymmetry)

- **Add point:** button + keyboard shortcut in the timeline — creates a point at the
  playhead (default span: current break's high-audio window, else ±4s), immediately
  draggable. Recorded as `pointAdded`.
- Added points participate in everything: scoring, export, training-clip extraction
  (they are *rally* labels — the exact examples the current model missed, the highest-value
  training data we can collect).
- **Undo/redo** (⌘Z/⇧⌘Z) via ledger replay.
- Review-state chips per point: `auto / confirmed / edited / added / deleted`.

### 3.3 Export: selection policies + wired render options (G3)

```swift
struct ExportPlan {
    var reels: Set<Reel>                // [.scoring, .highlights]
    enum Reel { case scoring            // all active points
                case highlights }       // top-K by highlight score
    var highlightSelection: HighlightSelection  // .topPercent(20) | .topMinutes(3) | .threshold(0.7)
    var individualClips: Bool           // also emit one file per selected point
    var scoreOverlay: Bool              // burn PointScore into scoring reel (v2.1)
    var transition: TransitionStyle     // .cut now; .crossfade v2.1
    var matchSourceFormat: Bool
}
```

- `VideoExporter` gains `export(plan:points:)`; `exportRallyOnly` becomes the
  `.scoring`-only degenerate case. Individual clips = loop of single-range exports.
- Export tab summary shows per-reel duration/size estimates.
- **Score overlay** (v2.1): Core Animation layer over the composition
  (`AVVideoCompositionCoreAnimationTool`) rendering `PointScore` per segment — the
  feature that makes "scoring reel" genuinely about *scoring*.

### 3.4 Highlight scoring (G7) — heuristic first, learned later

**Phase A — transparent heuristic, zero new ML.** Per point, from existing `FeatureFrame`s:

| Feature | Source | Intuition |
|---|---|---|
| `duration` | segment | long exchanges |
| `hitCount` | audio peaks within point | shot count |
| `tempo` | hitCount / duration | fast exchanges |
| `maxShuttleSpeed` | max Δ`shuttlecockPosition` per Δt | smashes |
| `avgMotion` | mean motionScore | intensity |
| `climax` | audio in last 1.5s vs point mean | dramatic finish |

Each normalized to in-video percentile → weighted sum → `highlightScore ∈ [0,1]`.
Default weights: duration .25, tempo .20, maxSpeed .20, hitCount .15, climax .12, motion .08.
Shown as a badge on each point row; sortable; slider selects top-K live.

**Phase B — personal ranker.** 👍/👎 ratings (ledger `highlightRated`) accumulate into a
second training pool. At ≥ ~30 ratings, train a Create ML **tabular classifier/regressor**
over the 6 features (seconds to train, fully on-device). Same gated-rollout rules as the
hit model (§3.5). Taste is personal — this is the app's best candidate for per-user learning.

### 3.5 Model lifecycle: registry, shadow eval, gated rollout (G6)

**Registry layout:**

```
Application Support/BadmintonVideoCutter/models/
  hit_classifier/
    v001/ model.mlmodelc  metadata.json
    v002/ ...
    current -> v002        # symlink or pointer file
  highlight_ranker/
    ...
```

`metadata.json`: trained date, clip/rating counts, training accuracy, **shadow-eval results**,
promoted (bool), notes.

**Shadow evaluation (the FSD "shadow mode"):** after training a candidate model and
*before* promoting it:

1. For every session with ledger corrections + cached `frames.bin`:
   re-run `AudioAnalyzer → HybridSegmenter → …` with the candidate model (seconds, no
   video decode).
2. Score against the user's corrected ground truth:
   - point-level **precision / recall** (match = IoU ≥ 0.5 with a non-deleted point),
   - **boundary MAE** (seconds) on matched points,
   - count of user-*added* points now found (the metric that matters most).
3. **Gate:** promote only if `F1(candidate) ≥ F1(current) − ε` and added-point recall
   does not regress. Otherwise keep current, store the candidate as unpromoted, and show
   the user the comparison.
4. UI: model panel lists versions with metrics; one-click **revert**; "why wasn't v004
   promoted?" shows the eval diff.

Existing `min 15 rally + 15 background clips` gate stays as the *pre*-training gate;
shadow eval is the *post*-training gate.

**Division of learning (what retrains vs what doesn't):**

| Layer | Learns from user? | Mechanism |
|---|---|---|
| TrackNetV3 (shuttle perception) | **No** — objective, general | Replace only via upstream better model (§5) |
| hit_classifier (audio) | Yes | Clip pool (exists) + gated rollout (new) |
| highlight_ranker (taste) | Yes | 👍/👎 pool → tabular model |
| Segmentation thresholds | Yes, indirectly | Per-venue profiles (§3.6), tuned from corrected sessions |

### 3.6 Config unification + venue profiles (G5)

1. Move hardcoded shuttle-primary constants from `HybridSegmenter` into `AnalysisConfig`:
   blend weights, Otsu clamp `[0.25, 0.55]`, split `maxDuration`, dip weights/sensitivity
   ladder, merge/absorption constants. Presets map onto them; defaults unchanged
   (verify via existing segmentation tests — cached TestData frames make this cheap).
2. **Venue profile** = named `AnalysisConfig` overlay + optional calibration reference,
   auto-suggested for new videos (start: manual pick; later: match by visual fingerprint).
3. Advanced disclosure in UI exposes a *small* curated subset (max rally length, split
   sensitivity, highlight weights); everything else stays preset-driven.

### 3.7 Customization ladder (progressive disclosure)

| Tier | User sees | Status |
|---|---|---|
| 1 | Sensitivity preset (conservative/balanced/aggressive) | exists |
| 2 | Advanced knobs (few, curated) | new — §3.6 |
| 3 | Venue profiles | new — §3.6 |
| 4 | Personal models panel (versions, metrics, train, revert) | new — §3.5 |
| 5 | Bring-your-own `.mlmodel` (documented I/O contract: 9×288×512 → 3 heatmaps; drop into Application Support — loader already supports it) | mostly free |

---

## 4. UI redesign — "simple but elegant"

Design principles: **one window, one obvious flow, direct manipulation on the timeline,
progressive disclosure for power features, no modes that hide data.**

Current pain: 4 tabs (Videos / Timeline / Rm Stats / Export) fragment one task across
modes; training UI is buried inside the Videos tab; Rm Stats is a whole tab for one
number table.

### Option A — "Studio": three-pane editor (recommended)

Single window, no tabs. Library → Canvas → Inspector, like Final Cut / Photos.

```
┌──────────┬──────────────────────────────────┬─────────────┐
│ LIBRARY  │            PLAYER                │  INSPECTOR  │
│ ▸ videos │                                  │ [Points]    │
│  ● 8510  │        (video preview)           │ [Export]    │
│  ● 6155  │                                  │ [Models]    │
│  ○ 6156  ├──────────────────────────────────┤             │
│          │ TIMELINE ▬▬▬__▬▬▬▬_▬▬__▬▬▬▬▬     │ point list  │
│ Analyze▶ │ (rallies, drag handles, +point)  │ w/ ⭐ score │
└──────────┴──────────────────────────────────┴─────────────┘
```

- Left: video library with status dots, preset picker, Analyze button.
- Center: player + full-width timeline (drag boundaries, add point, seek, dip graph
  as collapsible lane).
- Right: inspector with segmented switch — **Points** (review list, highlight badges,
  👍/👎), **Export** (policy checkboxes + summary; stats absorbed here), **Models**
  (training pool, versions, train/revert).
- Pros: everything about one video visible at once; standard editor mental model; stats
  and training stop being destinations. Cons: biggest refactor of the three.

### Option B — "Flow": guided stepper

Linear steps across the top: `Import → Analyze → Review → Export`. One focused screen per
step, Back/Next. Simplest possible mental model, best for casual/first-time users;
weakest for iterate-heavy review (constant step-switching), hides the learning loop.

### Option C — "Refined tabs": consolidation, minimal refactor

Keep tabs but reduce to **Review** (player + timeline + point list merged) and **Export**
(with stats absorbed); move training/models to a sheet or settings window. Cheapest,
preserves current code shape; still modal, still splits review from library.

**Recommendation: Option A.** It matches "simple but elegant" best — the simplicity comes
from *removing modes*, not removing capability — and Options B/C can't cleanly host the
highlight-review loop (⭐ scores + 👍/👎 live next to the player). Migration is tractable:
existing `TimelineTabView` internals (player, confidence graph, trim overlay) move nearly
intact into the center pane; `PointListView` into the inspector.

**➡ DECIDED: Option A "Studio"** (user pick, 2026-07-18 — DECISIONS.md D-003).

---

## 5. ML model upgrades (research findings, 2026-07-18)

Web research across shuttle trackers, badminton datasets, pose, audio, and highlight
literature; 21 load-bearing claims verified against primary sources. **Headline: the
current architecture is validated by 2024–2026 literature** — shuttle-trajectory
presence/gradients *are* the published basis for rally-boundary detection, and nothing
openly licensed clearly beats TrackNetV3 on badminton. The wins are additions, not swaps.

### 5.1 Adopt

| What | Why | How |
|---|---|---|
| **Trajectory-based hit detection** (Sensors 2024, [mdpi.com/1424-8220/24/13/4372](https://www.mdpi.com/1424-8220/24/13/4372)) | Hits from TrackNet trajectory alone (y-peak + direction-change identification) = F1 72.3%; fused with a swing/audio signal → **F1 90.5%** on 69 BWF matches. Zero new ML — pure math over existing `shuttlecockPosition`. | New `HitDetector` over FeatureFrames → per-hit timestamps. Improves `splitLongRallies` dips, gives **shot counts** for §3.4 highlight features. Slot into Phase 4. |
| **Audio hit-timing upgrade** | `MLSoundClassifier` (frozen VGGish head, ≥0.5s windows) is structurally incapable of ms-accurate hits — matches the observed 0.00/0.25 quantization. Literature: energy-peak onsets alone = 91% precision (Tsinghua); audio+visual+timing fusion adds 10–30 F1 pts (IBM AVSP 2011). | vDSP energy-peak onset detection (no ML), windows gated by trajectory direction-changes. Keep MLSoundClassifier for coarse rally/break only. Phase 4/8. |
| **Crowd-excitement signal** | Apple's built-in `SNClassifySoundRequest` (macOS 12+) ships 300+ classes incl. applause/cheering — free highlight feature, no model to ship. | Add `cheerScore` per point → highlight scorer §3.4. |
| **Highlight recipe validated** | Duration + shot count + motion stats + cheer is exactly what commercial systems (IBM US Open, WSC) use; CASA 2020 ranked badminton segments by player velocity. | Confirms §3.4 design as-is. |

### 5.2 Watch (revisit when the feature matters)

- **TrackNetV4** (ICASSP 2025, MIT): motion-attention module, ~+0.5pt over V3 — only try
  if fast-smash tracking failures show up. [github.com/TrackNetV4](https://github.com/TrackNetV4/TrackNetV4)
- **WASB** (BMVC 2023, MIT, NTT): 1.5M-param HRNet, very ANE-friendly — adopt only if V3
  speed/size becomes a problem. [github.com/nttcom/WASB-SBDT](https://github.com/nttcom/WASB-SBDT)
- **BST stroke-type transformer** (CVPRW 2026, MIT, 1.87M params): smash/clear/drop/net
  classification from RTMPose joints + TrackNetV3 trajectory — the big *shot-stats*
  feature unlock, at the cost of adding pose. [github.com/Va6lue/BST-Badminton-Stroke-type-Transformer](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer)
- **Pose**: skip for rally segmentation (BST ablation: trajectory ≈ 4× more signal than
  player position). If added later for serve/hit attribution: prototype with Apple Vision
  `VNDetectHumanBodyPoseRequest` (free, multi-person 2D), upgrade to RTMPose-m
  (Apache-2.0) via ONNX→CoreML if far-court players fail.
- **Datasets**: ShuttleSet (MIT, 36,492 strokes w/ hit frames) for ground truth;
  BFMD (19 matches, 1,687 rally boundaries) is ideal but **has no license — contact
  authors first**. [github.com/wywyWang/CoachAI-Projects](https://github.com/wywyWang/CoachAI-Projects)
- **Scoreboard OCR** (`VNRecognizeTextRequest` + scoring finite automaton, arXiv
  1801.01430): only relevant if users import broadcast footage.

### 5.3 Skip

TrackNetV5 (proprietary weights, no license) · MonoTrack (Adobe noncommercial license)
· YOLO-family shuttle detectors (single-frame trails temporal heatmaps; Ultralytics is
AGPL) · Sapiens pose (CC-BY-NC) · Moment-DETR/UniVTG highlight models (text-query
grounding, overkill).

### 5.4 Competitive note

**RallyCut** (App Store id6752290110, $9.99/yr, active solo dev) already does on-device
rally auto-clipping + dead-time removal for badminton on macOS — rally cutting alone is
table stakes. Differentiators per this design: **highlight ranking that learns your
taste** (§3.4-B), **score overlay** (§3.3), the **correct-and-learn loop** (§3.5), and
shot-type stats later (BST). Feature classes surfaced by Chinese competitors worth
borrowing eventually: smash detection, net saves, longest exchanges, top-20 rallies.

---

## 6. Phasing

Ordered so that (a) the ledger unblocks everything, (b) the UI shell lands *before* new
affordances so buttons aren't built twice, (c) ML risk is isolated at the end.

| Phase | Deliverable | Gaps closed |
|---|---|---|
| 0 | Branch + design docs (this) | — |
| 1 | **Corrections ledger** + session persistence + cached frames + undo | G1, G4, G8 |
| 2 | **UI shell redesign** (per chosen option), no new features | — |
| 3 | **Review affordances**: add-point, review chips, 👍/👎 capture | G2 |
| 4 | **Highlight scoring** (heuristic) + selection UI | G7 |
| 5 | **Export policies** wired end-to-end (+ individual clips) | G3 |
| 6 | **Model registry + shadow eval + gated rollout**; config unification | G5, G6 |
| 7 | **Learned ranker** (from ratings); score overlay; crossfade | — |
| 8 | **ML upgrades** per §5 research | — |

Each phase = one or more commits on `v2-redesign`, tracked in
[PROGRESS.md](PROGRESS.md); every non-obvious choice logged in
[DECISIONS.md](DECISIONS.md).

## 7. Testing strategy

- Every phase keeps the existing segmentation tests green (cached `TestData/` frames).
- Phase 1 adds `SessionStoreTests` (event append/replay/materialize round-trip; video
  identity stability).
- Phase 6 adds `ShadowEvalTests` (precision/recall/boundary-MAE math on synthetic
  ledgers).
- Highlight scorer gets golden tests over the 5 cached videos (top-3 points stable).
- `xcodebuild clean` before test runs (stale-build gotcha).
