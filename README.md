# Badminton Video Cutter (macOS)

Baseline scaffold for a SwiftUI macOS app that imports iPhone badminton videos, segments rally vs between-points intervals, and exports edited timelines.

## Current scaffold includes
- App entry + main ContentView
- Module folders:
  - `App`
  - `Domain`
  - `VideoIO`
  - `Segmentation`
  - `ModelMgmt`
  - `UIComponents`
- Placeholder AVKit player pane and timeline UI
- Initial domain models and protocols
- Unit test skeletons for Domain + Segmentation

## Folder layout
```text
BadmintonVideoCutter/
  App/
  Domain/
  VideoIO/
  Segmentation/
  ModelMgmt/
  UIComponents/
BadmintonVideoCutterTests/
  DomainTests/
  SegmentationTests/
```

## Generate Xcode project
This repo includes an `project.yml` for XcodeGen.

1. Install XcodeGen (if needed):
   - `brew install xcodegen`
2. Generate project:
   - `cd ~/Documents/badminton_video_cutter`
   - `xcodegen generate`
3. Open:
   - `open BadmintonVideoCutter.xcodeproj`

## Build
- Choose `BadmintonVideoCutter` scheme in Xcode
- Build and run on macOS 14+

## Next
- Wire `Import Video` to file importer + AVAsset loading
- Add feature extraction pipeline (motion + audio)
- Add hybrid segmentation + state machine rules
- Add export pipeline for between-points-only output
