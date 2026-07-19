# Decision Log

Non-obvious choices and their rationale, so future work doesn't relitigate them.
Format: ID, date, decision, why, alternatives rejected.

---

## D-001 · 2026-07-18 · Scoring vs highlights = selection policies, not modes

**Decision:** One detection pipeline; "scoring reel" and "highlight reel" are selection
policies applied at export (DESIGN.md §1, §3.3).
**Why:** Avoids two divergent pipelines; enables combinations (both reels from one
analysis); highlight selection is a ranking problem layered on existing rally detection.
**Rejected:** Separate "highlight detection" segmentation mode — would duplicate the
pipeline and still need rally boundaries anyway.

## D-002 · 2026-07-18 · Ledger before everything else

**Decision:** Phase 1 is the corrections ledger (append-only events + snapshot + cached
frames per video).
**Why:** Persistence, undo, training labels, and the shadow-eval corpus all fall out of
one mechanism. Building any learning feature before it means collecting no data in the
meantime and double work later.
**Rejected:** Jumping straight to highlight scoring (more visible, but its 👍/👎 signal
would have nowhere durable to live).

## D-003 · 2026-07-18 · UI direction: Option A "Studio"

**Decision:** Single-window three-pane layout — library left, player + timeline center,
inspector right (Points / Export / Models). See DESIGN.md §4.
**Why:** User pick (confirmed 2026-07-18). Simplicity via removing modes, not
capability; review + rating + export coexist without tab switching; best host for the
highlight/learning loop.
**Rejected:** B "Flow" stepper (weak for iterate-heavy review), C "Refined tabs"
(cheapest but still modal).

## D-004 · 2026-07-18 · TrackNetV3 is not user-retrainable

**Decision:** User feedback retrains only the cheap/personal layers (audio hit
classifier, highlight ranker, threshold profiles) — never the shuttle perception model
on-device.
**Why:** Shuttle detection is objective and general; on-device retraining of a heatmap
CNN is slow, fragile, and the failure mode (degraded perception) poisons everything
downstream. Mirrors the FSD split: fleet-wide perception, per-driver behavior profiles.
**Rejected:** MLUpdateTask personalization of TrackNetV3.

## D-005 · 2026-07-18 · Shadow eval gates every model promotion

**Decision:** A newly trained model replays all ledger-corrected sessions from cached
frames and must not regress F1 / added-point recall before becoming `current`; previous
versions kept for one-click revert (DESIGN.md §3.5).
**Why:** Continual retraining without an eval gate rots silently — already observed the
failure class in v1 tuning ("adaptive thresholds → tiny splits → mega-segments").
**Rejected:** Trust-the-latest-training-run (current behavior: overwrite in place).

## D-006 · 2026-07-18 · Ledger records point boundaries, not trim boundaries

**Decision:** Boundary drags are logged as `boundaryChanged` on the adjacent *point*;
no `trimBoundaryChanged` event exists. Undo/redo are appended as events (`undo`/`redo`)
and resolved at materialize time, keeping the ledger strictly append-only.
**Why:** Trim segments are re-derived from points on every change, so their IDs are
unstable — events referencing them would dangle. The timeline UI already mirrors every
trim-handle drag onto the adjacent point boundary, which carries the same information
with a stable ID. Append-only undo preserves the full audit trail (an undone action is
still visible in history).
**Rejected:** Logging trim IDs (dangling refs); truncating the ledger on undo (loses
audit; complicates concurrent readers).
