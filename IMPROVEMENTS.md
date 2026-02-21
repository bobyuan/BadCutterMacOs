# Detection & UI Improvements

Summary of improvements made to the rally detection pipeline and UI.

## Motion Detection

### Dynamic Resolution Analysis
- Upgraded from fixed 320x180 to half-native resolution (capped at 960x540)
- At 960x540, the shuttlecock is ~20-30px diameter — large enough for blob detection
- Previously at 320x180, the shuttlecock was only 2-5px (indistinguishable from noise)

### White-Pixel Displacement
- Replaced grayscale frame differencing with RGBA-based white-pixel tracking
- Identifies bright white pixels (luminance > 200, low saturation) that changed position between frames
- Static white objects (court lines, net) contribute zero since they don't move
- Skips top 20% of frame to exclude ceiling lights in indoor courts

### Multi-Region Motion Spread
- 6x4 coarse grid overlaid on the analysis area
- Counts how many regions have >1.5% of pixels moving
- During rallies, 3-4 players move simultaneously across the court (6-12 active regions)
- During breaks, 0-1 people move (0-3 active regions)
- Normalized: 8+ active regions = full score

### Velocity-Based Shuttlecock Tracking
- Connected component blob analysis on a 16px grid of displaced white pixels
- Finds small, compact blobs (1-8 grid cells) matching the shuttlecock profile
- Frame-to-frame velocity matching: the shuttlecock is the fastest-moving small white object
- Low velocity threshold (5px) catches slow net shots and short returns
- Tracking confidence builds over consecutive frames (3+ = confirmed flight)
- Graceful decay (600ms) when birdie is briefly undetected between hits

### Motion Tempo Detection
- Computes stddev of motion scores in a 3-second sliding window
- Rally exchanges produce oscillating patterns (hit-pause-hit) with high variance
- Break movement (walking, picking up birdie) is steady with low variance
- Applied as a post-processing multiplier: high tempo unchanged, low tempo reduced 40%
- Normalized using 95th percentile

### Vision Person Detection
- Uses Apple Vision framework `VNDetectHumanRectanglesRequest` to count players on court
- Runs every ~2 seconds (every 10th analyzed frame) for performance
- Calibrated to actual detection distribution at typical badminton camera distance:
  - 0 detected: no boost (likely break)
  - 1 detected: 0.3 boost
  - 2 detected: 0.85 boost (multiple players active)
  - 3+ detected: full boost

### Signal Blending
Five signals combined into a single motion score:
```
generalMotion * (0.2 + 0.2*shuttlecock + 0.25*spread + 0.35*playerPresence)
```
Then adjusted by motion tempo multiplier: `score * (0.6 + 0.4 * tempoScore)`

Creates ~5x gap between full rally and full break scores.

## Audio Detection

### Onset Detection Fixes
- Changed spectral flux normalization from global max to 95th percentile
  - One loud smash no longer suppresses all soft hits
- Lowered intensity floor from 0.18 to 0.08 (detects soft net shots)
- Reduced minimum cluster size from 3 to 2 (catches short 2-hit rallies)

### Audio as Pure Bonus
- Motion is the full base signal (100%), audio only adds on top
- Old: `0.90 * motion + 0.10 * audio` (motion reduced to 90%)
- New: `motion + 0.10 * audio` (motion at full value, capped at 1.0)
- Active playing scenes with audio=0 are no longer penalized

## Segmentation Timing

### Pre-Roll & Post-Roll
- Pre-roll increased 1.5s to 2.5s — captures serve preparation that was being missed
- Post-roll added at 1.5s — extends rally end to capture birdie landing after last hit
  - Players may stop moving 1-3 seconds before the point actually ends (they know they can't reach the bird)

### Gap Tolerance
- `minBetweenPointsDuration` increased 1.5s to 3.0s
  - A brief 2-second pause (player stops while birdie flies) no longer ends the rally
- `flipHysteresisSeconds` increased 1.0s to 1.5s (more resistance to state flips)
- `minDipDuration` increased to 3.0s (consistent with gap tolerance)

## UI Improvements

### Timeline Horizontal Scrolling
- Two-finger trackpad swipe or shift+scroll wheel pans the zoomed timeline left/right
- Uses NSView-based scroll wheel handler on the confidence graph and trim timeline

### Trim Zone Video Overlay
- Semi-transparent red overlay appears on the video player when the playhead is inside a trim segment (content to be removed)
- Overlay hides automatically when playhead enters a kept segment
- Flagged (kept) trim segments do not trigger the overlay

### Shuttlecock Flight Chart
- Green "Shuttle" line added to the confidence graph
- Displays shuttlecock in-flight confidence alongside motion (blue) and audio (orange)
- Based on velocity-tracked blob detection across consecutive frames

## Architecture

### Key Files
| File | Role |
|------|------|
| `Segmentation/BasicFeatureExtractor.swift` | Motion detection, shuttlecock tracking, Vision person detection |
| `Segmentation/AudioAnalyzer.swift` | Spectral flux onset detection, rally scoring |
| `Segmentation/HybridSegmenter.swift` | Rally/break classification, pre/post-roll, rally splitting |
| `Domain/Models.swift` | AnalysisConfig with all tuning parameters |
| `Domain/Protocols.swift` | FeatureFrame struct (motion, audio, shuttlecockFlight) |
| `UIComponents/TimelineTabView.swift` | Timeline, confidence graph, trim overlay, scroll handling |

### FeatureFrame Signals
Each analyzed video frame carries three scores:
- `motionScore` — blended motion signal (5 sub-signals + tempo adjustment)
- `audioScore` — cluster-based onset density from spectral flux analysis
- `shuttlecockFlightScore` — velocity-tracked shuttlecock in-flight confidence
