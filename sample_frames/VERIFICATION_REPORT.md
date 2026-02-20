# Visual Verification Report — Motion Detection vs Ground Truth

**Video**: `/Users/boyuan/Downloads/IMG_8510.MOV` (~13 min, doubles badminton)
**Date**: 2026-02-20
**Method**: 24 frames extracted at timestamps spanning the full motion score range (LOWEST to HIGHEST), visually inspected for actual scene content.

## Frame-by-Frame Analysis

### LOWEST motion (score = 0.000) — All correctly non-playing

| Frame | Timestamp | Motion | Audio | Classification | Visual Ground Truth | Correct? |
|-------|-----------|--------|-------|----------------|---------------------|----------|
| 01 | 0.13s | 0.000 | 0.000 | BETWEEN | 4 players standing still, pre-game | YES |
| 02 | 743.78s | 0.000 | 0.000 | BETWEEN | 1 player standing alone, others left court | YES |
| 03 | 744.44s | 0.000 | 0.000 | BETWEEN | Same player barely moved, waiting | YES |
| 04 | 745.95s | 0.000 | 0.000 | BETWEEN | Same, still standing | YES |

### P25 motion (score ~ 0.296) — Mixed results

| Frame | Timestamp | Motion | Audio | Classification | Visual Ground Truth | Correct? |
|-------|-----------|--------|-------|----------------|---------------------|----------|
| 05 | 72.00s | 0.296 | 0.333 | RALLY | 4 players in ready positions on court | YES |
| 06 | 328.94s | 0.296 | 0.000 | BETWEEN | **Active rally — 4 players, one hitting overhead, all in athletic stances** | **NO — should be RALLY** |
| 07 | 354.78s | 0.296 | 0.167 | RALLY | Players in positions, looks like active play | YES |
| 08 | 660.24s | 0.296 | 0.167 | RALLY | **Players at sideline drinking water, one sitting on floor** | **NO — should be BETWEEN** |
| 09 | 732.44s | 0.296 | 0.000 | BETWEEN | Players walking, hand to face, resting | YES |

### MEDIAN motion (score ~ 0.356) — Multiple misclassifications

| Frame | Timestamp | Motion | Audio | Classification | Visual Ground Truth | Correct? |
|-------|-----------|--------|-------|----------------|---------------------|----------|
| 10 | 5.80s | 0.356 | 0.500 | RALLY | 4 players in ready positions | YES |
| 11 | 30.98s | 0.356 | 0.000 | BETWEEN | **Active play — all 4 players on court in dynamic positions** | **NO — should be RALLY** |
| 12 | 81.83s | 0.356 | 0.000 | BETWEEN | Players standing between rallies, somewhat relaxed posture | YES (borderline) |
| 13 | 131.02s | 0.356 | 0.000 | BETWEEN | Players between points, relaxed | YES |
| 14 | 367.45s | 0.356 | 0.333 | RALLY | 4 players in positions, near-side serving stance | YES |

### P75 motion (score ~ 0.435) — Key misclassification found

| Frame | Timestamp | Motion | Audio | Classification | Visual Ground Truth | Correct? |
|-------|-----------|--------|-------|----------------|---------------------|----------|
| 15 | 42.48s | 0.435 | 0.333 | RALLY | Active play, players moving | YES |
| 16 | 104.34s | 0.435 | 0.333 | RALLY | Active play | YES |
| 17 | 448.99s | 0.435 | 0.167 | ? (gap) | Players walking to positions, between points | (correct if BETWEEN) |
| 18 | 485.83s | 0.435 | 0.667 | RALLY | Active play | YES |
| 19 | 583.54s | 0.435 | 0.000 | BETWEEN | **Active rally — 4 players, far-right lunging for shot** | **NO — should be RALLY** |

### HIGHEST motion (score = 1.000) — Mostly correct

| Frame | Timestamp | Motion | Audio | Classification | Visual Ground Truth | Correct? |
|-------|-----------|--------|-------|----------------|---------------------|----------|
| 20 | 721.43s | 1.000 | 0.000 | RALLY | 2 players mid-rally, motion blur on arms | YES |
| 21 | 767.95s | 1.000 | 0.500 | RALLY | Players walking/switching sides, heavy motion blur | BORDERLINE (transitioning, not rally) |
| 22 | 768.12s | 1.000 | 0.500 | RALLY | Similar transition scene | BORDERLINE |
| 23 | 770.62s | 1.000 | 0.333 | RALLY | Active rally, player swinging racket with blur | YES |
| 24 | 770.79s | 1.000 | 0.333 | RALLY | Active rally, heavy motion blur | YES |

## Summary

**Total frames inspected**: 24
**Correctly classified**: 17 (71%)
**Misclassified**: 4 (17%)
**Borderline/ambiguous**: 3 (12%)

### Misclassification pattern

| # | Timestamp | Motion | Audio | Classified | Should Be | Root Cause |
|---|-----------|--------|-------|------------|-----------|------------|
| 1 | 328.94s | 0.296 | **0.000** | BETWEEN | RALLY | Audio=0 during active play |
| 2 | 30.98s | 0.356 | **0.000** | BETWEEN | RALLY | Audio=0 during active play |
| 3 | 583.54s | 0.435 | **0.000** | BETWEEN | RALLY | Audio=0 during active play |
| 4 | 660.24s | 0.296 | **0.167** | RALLY | BETWEEN | Audio false-positive during break |

**All 3 false-negatives (active play marked BETWEEN) have audio = 0.000.**
The audio onset system fails to detect hits during these rallies, and the combined scoring formula still penalizes the total score enough to push them below the classification threshold.

**The 1 false-positive (break marked RALLY) has audio = 0.167.**
Background noise during a break gets misidentified as rally activity, boosting the combined score above the threshold.

### Root Cause

The audio rally score is unreliable in this recording environment:
- **False negatives**: Many racket hits don't produce enough spectral flux to trigger onset detection (possibly due to distance from camera microphone, gym acoustics, or soft hits in doubles play)
- **False positives**: Non-rally sounds (talking, shuffling, dropping things) get detected as onsets

Even with the reduced audio weights (65/35) and reduced multiplicative blend (70/30), the combined scoring still gives audio enough influence to flip classifications at the decision boundary.
