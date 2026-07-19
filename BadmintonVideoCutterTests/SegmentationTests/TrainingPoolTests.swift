import XCTest
@testable import BadmintonVideoCutter

final class TrainingPoolTests: XCTestCase {

    static let cacheDir = URL(fileURLWithPath: "/Users/boyuan/Documents/badminton_video_cutter/TestData")

    let video1URL = URL(fileURLWithPath: "/Users/boyuan/Downloads/IMG_8510.MOV")
    let video2URL = URL(fileURLWithPath: "/Users/boyuan/Downloads/IMG_6155.MOV")

    override func setUp() {
        super.setUp()
        // Start each test with a clean training pool
        HitModelTrainer.clearTrainingPool()
    }

    override func tearDown() {
        super.tearDown()
        // Clean up after tests
        HitModelTrainer.clearTrainingPool()
    }

    /// Full flow: load cached frames → build games → save clips → verify manifest → save 2nd video → verify → clear
    func testTrainingPoolFullFlow() async throws {
        // --- Step 1: Load cached frames for video 1 ---
        let frames1 = try loadCachedFrames(name: "IMG_8510_frames.json")
        XCTAssertFalse(frames1.isEmpty, "Should have cached frames for IMG_8510")
        print("Loaded \(frames1.count) frames for IMG_8510")

        // --- Step 2: Build game structure ---
        let segmenter = HybridSegmenter()
        let config = AnalysisConfig()
        let raw1 = segmenter.classify(frames: frames1, config: config)
        let processed1 = segmenter.postProcess(segments: raw1, frames: frames1, config: config)
        let refined1 = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(processed1), maxGap: 0.5)
        let games1 = GameDetector.detectGames(from: refined1, featureFrames: frames1)
        XCTAssertFalse(games1.isEmpty, "Should detect games for IMG_8510")
        let totalPoints1 = games1.reduce(0) { $0 + $1.activePointCount }
        print("IMG_8510: \(games1.count) games, \(totalPoints1) points")

        // --- Step 3: Verify pool starts empty ---
        let emptyManifest = HitModelTrainer.loadManifest()
        XCTAssertTrue(emptyManifest.videos.isEmpty, "Pool should start empty")
        print("Pool starts empty: OK")

        // --- Step 4: Save training clips for video 1 ---
        guard FileManager.default.fileExists(atPath: video1URL.path) else {
            XCTFail("Video not found: \(video1URL.path)")
            return
        }

        var progressMessages: [String] = []
        let entry1 = try await HitModelTrainer.saveTrainingClips(
            videoURL: video1URL,
            games: games1,
            featureFrames: frames1,
            progress: { msg in progressMessages.append(msg) }
        )

        print("Saved \(entry1.videoFileName): \(entry1.rallyClipCount) rally, \(entry1.backgroundClipCount) background clips")
        print("Progress messages: \(progressMessages)")

        XCTAssertEqual(entry1.videoFileName, "IMG_8510")
        XCTAssertGreaterThan(entry1.rallyClipCount, 0, "Should have rally clips")
        XCTAssertGreaterThan(entry1.backgroundClipCount, 0, "Should have background clips")

        // --- Step 5: Verify manifest on disk ---
        let manifest1 = HitModelTrainer.loadManifest()
        XCTAssertEqual(manifest1.videos.count, 1, "Manifest should have 1 video")
        XCTAssertEqual(manifest1.videos[0].videoFileName, "IMG_8510")
        XCTAssertEqual(manifest1.totalRallyClips, entry1.rallyClipCount)
        XCTAssertEqual(manifest1.totalBackgroundClips, entry1.backgroundClipCount)
        print("Manifest after video 1: \(manifest1.videos.count) videos, \(manifest1.totalRallyClips) rally + \(manifest1.totalBackgroundClips) bg clips")

        // --- Step 6: Verify WAV files exist on disk ---
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let trainingDir = appSupport.appendingPathComponent("BadmintonVideoCutter/training_data")
        let rallyDir = trainingDir.appendingPathComponent("rally")
        let bgDir = trainingDir.appendingPathComponent("background")

        let rallyFiles = (try? FileManager.default.contentsOfDirectory(atPath: rallyDir.path)) ?? []
        let bgFiles = (try? FileManager.default.contentsOfDirectory(atPath: bgDir.path)) ?? []
        XCTAssertEqual(rallyFiles.count, entry1.rallyClipCount, "Rally dir should have correct clip count")
        XCTAssertEqual(bgFiles.count, entry1.backgroundClipCount, "Background dir should have correct clip count")

        // Verify files are named with video prefix
        let prefix1 = entry1.clipPrefix
        XCTAssertTrue(rallyFiles.allSatisfy { $0.hasPrefix(prefix1) }, "Rally files should have video prefix")
        XCTAssertTrue(bgFiles.allSatisfy { $0.hasPrefix(prefix1) }, "Background files should have video prefix")

        // Verify WAV files have reasonable size (~88KB for 1s 44100Hz 16-bit mono)
        let sampleRallyURL = rallyDir.appendingPathComponent(rallyFiles[0])
        let fileSize = try FileManager.default.attributesOfItem(atPath: sampleRallyURL.path)[.size] as! Int64
        XCTAssertGreaterThan(fileSize, 80000, "WAV clip should be ~88KB")
        XCTAssertLessThan(fileSize, 100000, "WAV clip should be ~88KB")
        print("Sample WAV file size: \(fileSize) bytes")

        // --- Step 7: Save training clips for video 2 ---
        let frames2 = try loadCachedFrames(name: "IMG_6155_frames.json")
        XCTAssertFalse(frames2.isEmpty, "Should have cached frames for IMG_6155")

        let raw2 = segmenter.classify(frames: frames2, config: config)
        let processed2 = segmenter.postProcess(segments: raw2, frames: frames2, config: config)
        let refined2 = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(processed2), maxGap: 0.5)
        let games2 = GameDetector.detectGames(from: refined2, featureFrames: frames2)
        XCTAssertFalse(games2.isEmpty, "Should detect games for IMG_6155")
        let totalPoints2 = games2.reduce(0) { $0 + $1.activePointCount }
        print("IMG_6155: \(games2.count) games, \(totalPoints2) points")

        guard FileManager.default.fileExists(atPath: video2URL.path) else {
            XCTFail("Video not found: \(video2URL.path)")
            return
        }

        let entry2 = try await HitModelTrainer.saveTrainingClips(
            videoURL: video2URL,
            games: games2,
            featureFrames: frames2,
            progress: { _ in }
        )

        print("Saved \(entry2.videoFileName): \(entry2.rallyClipCount) rally, \(entry2.backgroundClipCount) background clips")
        XCTAssertEqual(entry2.videoFileName, "IMG_6155")
        XCTAssertGreaterThan(entry2.rallyClipCount, 0)
        XCTAssertGreaterThan(entry2.backgroundClipCount, 0)

        // --- Step 8: Verify manifest has both videos ---
        let manifest2 = HitModelTrainer.loadManifest()
        XCTAssertEqual(manifest2.videos.count, 2, "Manifest should have 2 videos")
        let videoNames = Set(manifest2.videos.map(\.videoFileName))
        XCTAssertEqual(videoNames, Set(["IMG_8510", "IMG_6155"]))
        XCTAssertEqual(manifest2.totalRallyClips, entry1.rallyClipCount + entry2.rallyClipCount)
        XCTAssertEqual(manifest2.totalBackgroundClips, entry1.backgroundClipCount + entry2.backgroundClipCount)
        print("Manifest after video 2: \(manifest2.videos.count) videos, \(manifest2.totalRallyClips) rally + \(manifest2.totalBackgroundClips) bg clips")

        // Verify file counts on disk
        let allRallyFiles = (try? FileManager.default.contentsOfDirectory(atPath: rallyDir.path)) ?? []
        let allBgFiles = (try? FileManager.default.contentsOfDirectory(atPath: bgDir.path)) ?? []
        XCTAssertEqual(allRallyFiles.count, manifest2.totalRallyClips)
        XCTAssertEqual(allBgFiles.count, manifest2.totalBackgroundClips)
        print("Disk file counts match manifest: \(allRallyFiles.count) rally, \(allBgFiles.count) bg")

        // --- Step 9: Re-save video 1 (should replace, not duplicate) ---
        let entry1b = try await HitModelTrainer.saveTrainingClips(
            videoURL: video1URL,
            games: games1,
            featureFrames: frames1,
            progress: { _ in }
        )

        let manifest3 = HitModelTrainer.loadManifest()
        XCTAssertEqual(manifest3.videos.count, 2, "Should still have 2 videos after re-save")
        // Total clips should be entry1b + entry2 (not entry1 + entry1b + entry2)
        XCTAssertEqual(manifest3.totalRallyClips, entry1b.rallyClipCount + entry2.rallyClipCount)
        XCTAssertEqual(manifest3.totalBackgroundClips, entry1b.backgroundClipCount + entry2.backgroundClipCount)
        print("After re-save: \(manifest3.totalRallyClips) rally + \(manifest3.totalBackgroundClips) bg (no duplicates: OK)")

        // Old prefix files should be gone
        let reRallyFiles = (try? FileManager.default.contentsOfDirectory(atPath: rallyDir.path)) ?? []
        let oldPrefixFiles = reRallyFiles.filter { $0.hasPrefix(prefix1) }
        XCTAssertTrue(oldPrefixFiles.isEmpty, "Old prefix clips should be removed on re-save")
        print("Old prefix clips removed on re-save: OK")

        // --- Step 10: Clear pool ---
        HitModelTrainer.clearTrainingPool()
        let emptyManifest2 = HitModelTrainer.loadManifest()
        XCTAssertTrue(emptyManifest2.videos.isEmpty, "Pool should be empty after clear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rallyDir.path), "Rally dir should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bgDir.path), "Bg dir should be removed")
        print("Pool cleared: OK")

        print("\n=== FULL TRAINING POOL FLOW TEST PASSED ===")
    }

    // MARK: - Helpers

    private func loadCachedFrames(name: String) throws -> [FeatureFrame] {
        let url = Self.cacheDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Cached frames not found: \(name)")
            return []
        }
        let data = try Data(contentsOf: url)
        let cached = try JSONDecoder().decode([CodableFrame].self, from: data)
        return cached.map { $0.toFeatureFrame() }
    }
}

// MARK: - Codable bridge (same as in HybridSegmenterTests)

private struct CodableFrame: Codable {
    let timestamp: TimeInterval
    let motionScore: Double
    let audioScore: Double
    let shuttlecockFlightScore: Double
    let posX: Double?
    let posY: Double?

    init(from frame: FeatureFrame) {
        self.timestamp = frame.timestamp
        self.motionScore = frame.motionScore
        self.audioScore = frame.audioScore
        self.shuttlecockFlightScore = frame.shuttlecockFlightScore
        self.posX = frame.shuttlecockPosition?.x
        self.posY = frame.shuttlecockPosition?.y
    }

    func toFeatureFrame() -> FeatureFrame {
        var f = FeatureFrame(timestamp: timestamp, motionScore: motionScore, audioScore: audioScore)
        f.shuttlecockFlightScore = shuttlecockFlightScore
        if let x = posX, let y = posY {
            f.shuttlecockPosition = (x: x, y: y)
        }
        return f
    }
}
