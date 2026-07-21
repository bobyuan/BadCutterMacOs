# Score Calculation & Adjustment — Design

Status: DRAFT for review · 2026-07-21
Companion docs: DESIGN.md (app architecture), DECISIONS.md (D-log)

## 1. Vocabulary and Invariants

- **Play (point)**: one rally, delimited by segmentation and user edits.
- **Serve side**: the physical court half (left/right or near/far, per the
  camera axis) whose party serves a given play.
- **Side A**: the party that serves the **first play of a game**. Every game
  has its own A. Scores always display `A:B`.
- **Winner rule** (rally scoring): **winner(N) = server(N+1)**. The serve-side
  sequence *is* the winner sequence, shifted by one. Corollary: server(N+1) =
  server(N) if and only if the server won play N.
- **Terminal rule**: a game ends at 21 with a 2-point lead; deuce extends to a
  2-point lead, capped at 30. No play may follow a terminal score.

Hard invariants (the ones users rely on):

1. **I-1 Backward stability**: correcting play N (winner, boundary of a later
   play, recalculation from N) never changes the displayed score of any play
   before N.
2. **I-2 Anchor immutability**: once any score-affecting correction is made in
   a game, the identity of A (the physical side) is frozen for that game.
3. **I-3 Pin supremacy**: a user pin always beats every automatic process,
   forever, and survives re-runs, re-detections, and re-analysis.
4. **I-4 Provenance visibility**: the user can always tell whether a displayed
   winner is *pinned*, *detected* (and how confidently), or *guessed*.
5. **I-5 Rules compliance**: a chain violating the terminal rule is visibly
   flagged and never silently accepted.

## 2. Layered Architecture

```
L0  Signals        shuttle positions (TrackNet, cached), motion frames,
                   audio onsets — per-play evidence around the serve moment
L1  Classification per-play serve-side likelihoods + confidence margin
L2  Sequence       whole-game inference over the serve-side sequence using
                   the winner rule + terminal rule (Viterbi-style smoothing)
L3  Anchoring      per-game A/B mapping (first play's side), frozen on
                   first correction
L4  Corrections    ledger events (pins), prefix freezing, swap A↔B,
                   reconciliation from a user-supplied final score
L5  Presentation   score columns, winner chips, provenance badges, legend
                   (real player figures), validation warnings
```

Each layer only feeds forward. Corrections (L4) mask L1/L2 output; they are
never overwritten by them (I-3).

## 3. L1 — Per-play Classification (redesign)

### 3.1 Current implementation (ServeDetector)

Motion centroid of two frame pairs at `start+0.1/0.5/0.9`, axis = larger
variance (x vs y), **median split** with a 0.02 dead zone; margin =
|value − median|.

### 3.2 Why the median split is structurally wrong

Rally scoring means **the winner keeps serving**. Serve sides are *not*
balanced: a 21:9 game has at least ~70% of serves from one side. The median
forcibly classifies half the plays to each side, so in any one-sided game a
large fraction of the dominant server's plays are **mechanically pushed to
the wrong side** — regardless of how good the centroid signal is. This is
the primary source of "mistakes after re-running score calculation".

Also broken:
- Frame-grab failures append a fake `(0.5, 0.5)` centroid that pollutes the
  distribution instead of being excluded.
- Margins measured from a median that sits *inside* a cluster are
  meaningless as confidence.
- The whole-frame centroid absorbs background motion (spectators, adjacent
  courts) and, in doubles, the partner and receiver.
- The 0.1–0.9s window is anchored to the play *start* (which includes
  pre-roll), not to the serve moment.

### 3.3 Redesigned classifier

1. **Shuttle-first**: the cached TrackNet `shuttlecockPosition` stream is the
   strongest signal — the shuttle's first appearances in a play originate at
   the server. Take the first K frames of the play with a position, average
   their axis value. No new ML, no video decode (frames are cached).
2. **Motion fallback**: keep the centroid only for plays with no early
   shuttle positions; exclude failed grabs entirely.
3. **Serve-moment anchoring**: if an audio onset exists in `start … start+2s`,
   center the sampling window on it (the serve hit) instead of raw start.
4. **Cluster split, not median split**: sort the values and split at the
   **largest interior gap** (1-D 2-means equivalent). Sides may be 80/20 —
   that's expected, not an anomaly. Dead zone = fraction of the gap.
5. **Margin**: distance to the split point normalized by cluster spread —
   comparable across runs, usable by L2 and reconciliation.
6. **Axis stability**: the axis is chosen once per video (first full
   detection) and persisted in the baseline; incremental re-detections reuse
   it. Changing axis requires a full re-analysis (it invalidates all stored
   side tokens).

## 4. L2 — Sequence Inference (new)

Per-play classification treats each serve independently, but the sequence is
heavily constrained: the serve-side sequence *is* the winner sequence. Use
it:

- **States**: side ∈ {left, right} per play.
- **Emissions**: L1 likelihoods (margin-weighted); pinned plays are hard
  constraints (probability 1).
- **Transitions**: free (either side can win any play) — but each full path
  implies a score chain; paths whose chain violates the terminal rule are
  pruned (or heavily penalized).
- **Output**: max-likelihood side sequence + per-play posterior → the
  *effective* serve sides and honest confidence.

Result: an isolated low-margin misdetection between two confident serves is
automatically corrected by its neighbors, and impossible chains (23:9) are
never produced in the first place — the validator becomes a safety net
instead of the primary defense.

Guesses disappear as a category: an unknown serve gets a posterior from its
neighbors instead of "leader won" (which biases toward A on ties and is
invisible to the user today).

## 5. L3 — Anchoring

- A(game) = effective side of the game's first active play.
- `freezeAnchorIfNeeded`: any correction in a game first pins the first
  play's side to the current anchor (I-2).
- `swapSides(for:)`: explicit user statement that the labeling is reversed;
  re-pins the first play to the opposite side. The only sanctioned way the
  anchor changes after freezing.
- The legend (header caption + real player figures via Vision) is the user's
  ground truth for *who* A is; it must always render from the same anchor
  the columns use.

## 6. L4 — Corrections and Durability

Durability tiers, strongest first:

| Tier | Source | Ledger event | Survives |
|------|--------|--------------|----------|
| P1 | Explicit user pin (winner menu, serve pin, swap) | `serveSideOverridden` / `pointWinnerOverridden` | everything |
| P2 | Implied pin (prefix freeze at correction time) | same events, recorded automatically | everything |
| P3 | Sequence-inferred side (L2) | none (derived) | until next inference run |
| P4 | Raw single-play detection (L1) | none | until next detection |

Semantics:

- **Correcting play N** (winner menu): records P2 pins for every play before
  N at their *displayed* values, then the correction itself. Selecting the
  already-believed winner is a no-op with an explanatory status message.
- **Recalculate from here**: P2-pins the prefix, clears P3/P4 strictly after
  N, re-runs L1+L2 for the suffix.
- **Fix score… (reconciliation)**: user supplies the true final score; flip
  the lowest-margin unpinned winners until the chain matches; report which.
- **Undo**: every correction is one ⌘Z away (ledger events).
- Pins can be *released* (planned): recording `side: unknown` returns a play
  to P3/P4 control (needed if a user pins a mistake and wants automation
  back; today the only escape is undo).

## 7. L5 — Presentation

- Score column `A:B` per play + winner chip (A blue / B orange).
- **Provenance badge (planned, I-4)**: pinned = solid chip; detected = plain;
  low-confidence/inferred = hollow or "?" — so a guessed winner never
  masquerades as a confident one.
- Game header: legend caption, player figures, ⇄ swap, validation ⚠️ +
  "Fix score…".

## 8. Re-run Semantics

A "re-run" (recalculate, re-detection after boundary edits, full re-analysis)
must be **monotone with respect to user knowledge**: it may only change plays
in tiers P3/P4. It reuses the persisted axis, respects all pins as hard
constraints in L2, and never touches rows above a recalculation point.

## 9. Testing

- Unit: chain rule, anchor stability, prefix freezing (ShadowEvalTests) —
  exists; extend with cluster-split and sequence-inference cases.
- Golden: cached TestData FeatureFrames → shuttle-first classification is
  fully testable offline (no video, no ML at test time).
- Property: for random winner sequences, generate the implied serve sequence,
  add noise, run L1+L2 → recovered chain must satisfy terminal rules and
  match the clean chain except at noise sites with adjacent noise.

## 10. Diagnostics

Two log files, overwritten on every run, for troubleshooting winner
detection (paste them into a session for analysis):

- **`/tmp/serve_detection_log.txt`** — classifier internals, written on every
  serve-detection pass: per play the motion centroid, chosen axis (with
  variances), the split value and dead zone, the play's axis value and
  margin, the resulting side, and any frame-grab failures.
- **`/tmp/score_detection_log.txt`** — winner-chain derivation, written on
  every score computation: per game the anchor (which physical side is A and
  why — pinned / detected / fallback) and any rules violation; per play the
  serve side with provenance (`PINNED` / `detected` / `missing`), the exact
  evidence that decided its winner ("next play (#7) served by left",
  "GUESS (…; assumed leader won)", "explicit final-play winner override"),
  and the running score.

Every guessed winner is marked `GUESS` — the first thing to look for when a
chain went wrong (G7: today these are invisible in the UI).

## 11. Known Gaps (as of 2026-07-21)

| # | Gap | Layer | Severity |
|---|-----|-------|----------|
| G1 | Median split misclassifies plays whenever serving is unbalanced (i.e. almost always) | L1 | **critical** |
| G2 | No sequence inference; isolated misdetections propagate straight into scores | L2 | **high** |
| G3 | Failed frame grabs recorded as (0.5, 0.5) centroids, polluting the split | L1 | high |
| G4 | Sampling window anchored to play start (pre-roll), not the serve moment | L1 | medium |
| G5 | Shuttle positions (cached, strong) unused for serve side | L1 | high |
| G6 | Axis re-chosen every detection run; can flip and scramble stored tokens | L1 | medium |
| G7 | Guessed winners ("leader won") indistinguishable from detected ones in UI | L5 | medium |
| G8 | Margins measured from the median are not real confidence; reconciliation ranks flips by them | L1/L4 | medium |
| G9 | No way to release a pin except undo | L4 | low |
| G10 | Doubles: centroid mixes partner/receiver; shuttle-first + serve-moment anchoring mitigates | L1 | medium |
