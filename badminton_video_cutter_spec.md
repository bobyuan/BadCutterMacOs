# Badminton Video Cutter — Product & Technical Spec (macOS)

## 1) Objective
Build a macOS app that imports iPhone badminton match videos and segments them into:
- `RALLY` (ball in play)
- `BETWEEN_POINTS` (dead time between rallies)

Primary export goal: **remove rally frames/time intervals** and keep only between-point footage (with optional inverse export for rally highlights).

---

## 2) MVP Product Flow
1. Import one or more iPhone videos (HEVC/H.264 MOV/MP4)
2. Analyze timeline and classify segments (`RALLY` vs `BETWEEN_POINTS`)
3. Show editable timeline with colored blocks
4. Allow manual boundary correction
5. Export:
   - Between-points-only video
   - Rally-only video (optional)
   - EDL/JSON segment list

---

## 3) Detection Strategy (Hybrid)
Use a weighted fusion model rather than one signal.

### 3.1 Motion Features (Computer Vision)
- Optical flow / frame differencing
- Sustained high movement patterns often indicate active rally
- Lower/irregular movement often indicates pauses

### 3.2 Audio Features
- RMS energy + spectral features
- Detect hit-like transients (racket impacts)
- Use repeated transient cadence as rally signal

### 3.3 Court/Player Context
- Court-line and player-region persistence
- Position/recovery patterns can separate rally vs downtime

### 3.4 Temporal State Machine
- Enforce minimum segment durations
- Apply hysteresis to avoid label flicker
- Example constraints:
  - Min rally duration: ~3s
  - Min pause duration: ~2s

---

## 4) Option Roadmap

## Option 1 (Recommended First)
Classical CV + audio + rules engine (no deep model at first):
- Fast to build
- Easy to debug
- Good baseline

## Option 2 (Accuracy Upgrade)
Temporal classifier (lightweight ML model):
- Labels short clips as rally/non-rally
- Uses post-processing rules for stability
- Can be fully local; remote endpoint optional

---

## 5) Local vs Remote Model (Option 2)

### Local-only (default recommendation)
- No external endpoint required
- Better privacy (video never leaves device)
- No API cost/latency

### Remote endpoint (optional)
Use only if needed for:
- Larger models/heavier compute
- Shared model ops across teams
- Centralized model rollout/control

---

## 6) Training Workflow Architecture
Same app can support training workflow without backend.

### In-App UX
- Import videos
- Label/correct segments
- Trigger retraining
- Evaluate metrics
- Activate latest model

### Local Trainer Component
- Runs as helper process/bundled runtime
- Saves model artifacts locally
- App hot-swaps active model version

Backend is optional, not required.

---

## 7) Shared Model Across Multiple macOS Instances
Use a versioned model artifact + manifest pattern.

### 7.1 Central Store
- S3 / R2 / GCS / GitHub Releases

### 7.2 Manifest-driven Updates
Include:
- model version
- checksum
- min app version
- metrics
- rollout controls (optional)

### 7.3 Client Update Flow
1. Fetch manifest
2. Compare versions
3. Download new artifact
4. Verify checksum/signature
5. Atomically switch active model
6. Keep rollback copy

---

## 8) Model Import/Export (Local File)

### 8.1 Package Format
Use `.btmodel` package:

```text
MyModel.btmodel/
  manifest.json
  model.mlmodelc            (or model.onnx / model.pt)
  labels.json
  thresholds.json
  metrics.json              (optional)
  signature.sig             (optional)
```

### 8.2 Manifest Contract (example)
```json
{
  "formatVersion": "1.0",
  "modelId": "badminton-rally-segmentation",
  "modelVersion": "2026.02.18.1",
  "createdAt": "2026-02-18T21:00:00Z",
  "framework": "coreml",
  "entryFile": "model.mlmodelc",
  "inputSchemaVersion": "1.0",
  "outputSchemaVersion": "1.0",
  "minAppVersion": "1.0.0",
  "sha256": "...",
  "notes": "Trained on mixed singles/doubles footage"
}
```

### 8.3 Import Flow
1. User picks `.btmodel` / `.zip`
2. Unpack to temp dir
3. Validate required files + schema
4. Verify checksum/signature
5. Run quick dry-run inference
6. Copy to local model store
7. Prompt to activate

### 8.4 Export Flow
1. Select active model version
2. Recompute checksum and update manifest
3. Package as `.btmodel`
4. Save atomically
5. Confirm path

### 8.5 Reliability Rules
- Never run model directly from external path
- Always stage into app model store first
- Keep previous model for rollback
- Log import/export history

---

## 9) Suggested macOS Tech Stack
- UI: SwiftUI
- Video I/O: AVFoundation
- Vision/CV: Vision + Core Image + Accelerate/Metal
- Audio features: AVAudioEngine + vDSP
- Export: AVAssetExportSession / custom composition
- Optional local ML: Core ML / PyTorch helper

---

## 10) Export Logic for “Remove Frames During Play”
Implementation should remove **time intervals**, not arbitrary individual frames:
1. Identify all `RALLY` intervals
2. Compute complement (`BETWEEN_POINTS`)
3. Concatenate kept segments
4. Re-encode with stable fps/timebase
5. Optionally apply short audio crossfades

Example segment JSON:
```json
{
  "video": "match1.mov",
  "segments": [
    {"start": 12.3, "end": 25.8, "label": "RALLY"},
    {"start": 25.8, "end": 39.1, "label": "BETWEEN_POINTS"}
  ]
}
```

---

## 11) UX Controls
- Sensitivity preset: Conservative / Balanced / Aggressive
- Singles vs doubles preset
- Court profile calibration (lighting/angle)
- Manual boundary edit tools
- “Learn from edits” feedback path

---

## 12) Phased Implementation Plan

### Phase 1 (MVP)
- Import/playback/export
- Motion+audio segmentation
- Editable timeline
- Between-point export

### Phase 2
- Court-aware feature improvements
- Batch processing
- Better state-machine tuning

### Phase 3
- Trainable classifier
- Active learning from user corrections
- Performance optimization (Metal)

---

## 13) Key Risks & Mitigations
- Shaky/handheld footage → stabilization or camera-motion compensation
- Noisy gym audio → robust transient filtering; avoid audio-only decisions
- Diverse camera angles → calibration + profile presets
- Processing speed → analyze at reduced fps; export full quality

---

## 14) Next Engineering Artifacts to Produce
1. `Architecture.md` (module boundaries + data contracts)
2. `ModelPackageSpec.md` (`.btmodel` schema/versioning)
3. `SegmentationRules.md` (state transitions/thresholds)
4. `TrainingPipeline.md` (local retrain/eval/deploy)
5. `SwiftInterfaces.md` (service protocols + async flows)
