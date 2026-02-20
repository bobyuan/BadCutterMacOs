# Future Detection Improvements

Approaches to improve rally vs break classification accuracy beyond the current system (shuttlecock blob detection + general motion + audio onset).

## Phase 2 Candidates

### Motion Tempo / Variance
- Compute variance of motion scores over a sliding window (5-10 frames / 1-2 seconds)
- Rally: rapid fluctuations (lunges, swings, recoveries)
- Break: steady low motion (walking, standing)
- Adds temporal dimension the current frame-by-frame approach misses
- Simple to compute from existing motion scores (no per-pixel work)
- Implementation: sliding window stddev on motionScore, stored as new FeatureFrame field

### Court-Region Focus
- Focus motion analysis on the playing court area only (~central 60% of frame), excluding sidelines
- Would reduce false positives from sideline movement during breaks
- Requires approximate court boundary detection
- Options: (a) use floor color (tan/beige wood) to detect court area, (b) use court line detection (colored lines visible), (c) hardcode approximate ROI based on typical camera angles
- Could mask out non-court pixels before motion computation

### Lower-Body Rapid Movement (Shoes/Feet)
- Track rapid lateral motion in the bottom 30% of the frame (foot/leg area)
- Rally: quick lateral steps, lunges, shuffling
- Break: slow walking or stationary
- Use color filtering to detect non-floor objects (dark shoes on tan court)
- Court floor is tan/beige (high luminance, warm hue), shoes are typically dark or brightly colored
- More complex signal, potentially noisy

### Player Count on Court
- Detect how many players are actively on the court during each frame
- Rally: typically 4 players in doubles
- Break: players may leave court, sit at sideline, cluster together
- Could use color-based clustering (orange vs black team jerseys)
- Or use person-sized blob detection
- Most complex to implement reliably without ML

## Notes from Verification (2026-02-20)
- Court: tan/beige wood floor, purple/blue walls, white court lines
- Player clothing: Team A = black/dark, Team B = orange/rust
- Shuttlecock: ~20-30px diameter at 960x540 (half-native)
- Main accuracy issue: audio=0 during active rallies (3/4 misclassifications)
- Motion-only accuracy estimated at ~88% vs 71% with audio-dependent scoring
