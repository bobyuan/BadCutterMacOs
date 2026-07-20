import Foundation
import CryptoKit

/// Per-video session persistence: an append-only correction ledger shared by
/// every analysis run, plus one directory per run, stored under
/// Application Support/BadmintonVideoCutter/sessions/<videoID>/
///
///   ledger.jsonl          append-only events (run-tagged), one JSON per line
///   meta.json             video identity + bookkeeping
///   current.json          which analysis run is active
///   runs/rNNN/
///     baseline.json       that run's analysis output
///     frames.json         cached FeatureFrames for replay
///     audio.json          onsets + cheer timeline
///
/// Re-analysis creates a new run; older runs (and the corrections made on
/// them) are never deleted, so the user can switch back at any time.
final class SessionStore {
    static let shared = SessionStore()

    let root: URL
    private var videoIDCache: [URL: String] = [:]
    private var nextSeqCache: [String: Int] = [:]

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            root = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport
                .appendingPathComponent("BadmintonVideoCutter")
                .appendingPathComponent("sessions")
        }
    }

    struct LoadedSession {
        var run: Int
        var baseline: SessionBaseline
        /// Events belonging to this run, in ledger order.
        var events: [SessionEvent]
        var frames: [FeatureFrame]
        var audioSignals: AudioSignals?
    }

    struct RunSummary: Identifiable, Equatable {
        var run: Int
        var savedAt: Date
        var pointCount: Int
        var eventSeqAtSave: Int

        var id: Int { run }
        var label: String { "Analysis #\(run)" }
    }

    // MARK: - Encoding

    private static let ledgerEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Video Identity

    /// Content-based ID stable across file renames/moves:
    /// SHA256(first 64KB + last 64KB + file size), truncated to 16 hex chars.
    func videoID(for url: URL) -> String? {
        if let cached = videoIDCache[url] { return cached }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunk = 65536
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size - Int64(chunk)))
            tail = (try? handle.read(upToCount: chunk)) ?? Data()
        }

        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: tail)
        hasher.update(data: Data("\(size)".utf8))
        let digest = hasher.finalize()
        let id = String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        videoIDCache[url] = id
        return id
    }

    func sessionDirectory(forVideoID videoID: String) -> URL {
        root.appendingPathComponent(videoID)
    }

    func sessionDirectory(for url: URL) -> URL? {
        videoID(for: url).map(sessionDirectory(forVideoID:))
    }

    // MARK: - Run Layout

    private struct CurrentRunPointer: Codable { var run: Int }

    func runDirectory(forVideoID vid: String, run: Int) -> URL {
        sessionDirectory(forVideoID: vid)
            .appendingPathComponent("runs")
            .appendingPathComponent(String(format: "r%03d", run))
    }

    /// Adopt a pre-versioning session (flat baseline.json etc.) as run 1.
    /// No-op when already migrated or nothing to migrate.
    func migrateLegacyLayout(forVideoID vid: String) {
        let fm = FileManager.default
        let dir = sessionDirectory(forVideoID: vid)
        let legacyBaseline = dir.appendingPathComponent("baseline.json")
        let runsDir = dir.appendingPathComponent("runs")
        guard fm.fileExists(atPath: legacyBaseline.path),
              !fm.fileExists(atPath: runsDir.path) else { return }

        let r1 = runDirectory(forVideoID: vid, run: 1)
        try? fm.createDirectory(at: r1, withIntermediateDirectories: true)
        for name in ["baseline.json", "frames.json", "audio.json"] {
            let src = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: r1.appendingPathComponent(name))
            }
        }
        setCurrentRun(1, forVideoID: vid)
    }

    /// Existing run numbers, ascending.
    func runNumbers(forVideoID vid: String) -> [Int] {
        migrateLegacyLayout(forVideoID: vid)
        let runsDir = sessionDirectory(forVideoID: vid).appendingPathComponent("runs")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: runsDir.path) else { return [] }
        return names.compactMap { name in
            name.hasPrefix("r") ? Int(name.dropFirst()) : nil
        }.sorted()
    }

    func currentRun(forVideoID vid: String) -> Int? {
        migrateLegacyLayout(forVideoID: vid)
        let url = sessionDirectory(forVideoID: vid).appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: url),
              let pointer = try? Self.decoder.decode(CurrentRunPointer.self, from: data) else {
            return runNumbers(forVideoID: vid).last
        }
        return pointer.run
    }

    func setCurrentRun(_ run: Int, forVideoID vid: String) {
        let url = sessionDirectory(forVideoID: vid).appendingPathComponent("current.json")
        if let data = try? Self.prettyEncoder.encode(CurrentRunPointer(run: run)) {
            try? data.write(to: url)
        }
    }

    /// Lightweight per-run info for the history UI.
    func runSummaries(forVideoID vid: String) -> [RunSummary] {
        runNumbers(forVideoID: vid).compactMap { run in
            guard let baseline = loadBaseline(forVideoID: vid, run: run) else { return nil }
            return RunSummary(
                run: run,
                savedAt: baseline.savedAt,
                pointCount: baseline.games.reduce(0) { $0 + $1.points.count },
                eventSeqAtSave: baseline.eventSeqAtSave
            )
        }
    }

    private func loadBaseline(forVideoID vid: String, run: Int) -> SessionBaseline? {
        let url = runDirectory(forVideoID: vid, run: run).appendingPathComponent("baseline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SessionBaseline.self, from: data)
    }

    // MARK: - Ledger

    /// Append an event tagged with the run it applies to. Returns the seq.
    @discardableResult
    func append(_ event: SessionEvent, for url: URL, run: Int? = nil) -> Int? {
        guard let vid = videoID(for: url) else { return nil }
        let dir = sessionDirectory(forVideoID: vid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")

        let seq = nextSeq(forVideoID: vid)
        let entry = LedgerEntry(seq: seq, ts: Date(), event: event, run: run ?? currentRun(forVideoID: vid))
        guard var data = try? Self.ledgerEncoder.encode(entry) else { return nil }
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: ledgerURL.path),
           let handle = try? FileHandle(forWritingTo: ledgerURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: ledgerURL)
        }
        nextSeqCache[vid] = seq + 1
        return seq
    }

    /// The seq the next appended event will get.
    func nextSeq(forVideoID vid: String) -> Int {
        if let cached = nextSeqCache[vid] { return cached }
        let next = (loadLedger(forVideoID: vid).last?.seq).map { $0 + 1 } ?? 0
        nextSeqCache[vid] = next
        return next
    }

    func loadLedger(forVideoID vid: String) -> [LedgerEntry] {
        let ledgerURL = sessionDirectory(forVideoID: vid).appendingPathComponent("ledger.jsonl")
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(LedgerEntry.self, from: Data(line.utf8))
        }
    }

    /// Ledger entries belonging to one run. Untagged (pre-versioning) entries
    /// belong to run 1 when their seq is inside that baseline's window.
    func ledgerEntries(forVideoID vid: String, run: Int) -> [LedgerEntry] {
        guard let baseline = loadBaseline(forVideoID: vid, run: run) else { return [] }
        return loadLedger(forVideoID: vid).filter { entry in
            if let tagged = entry.run { return tagged == run }
            return run == 1 && entry.seq >= baseline.eventSeqAtSave
        }
    }

    // MARK: - Baseline + Frames

    /// Persist a fresh analysis as a NEW run (never overwrites older runs)
    /// and point `current` at it. Returns the baseline and its run number.
    @discardableResult
    func saveBaseline(
        segments: [TimeSegment],
        games: [Game],
        serveSides: [UUID: ServeDetector.ServeSide],
        videoDuration: TimeInterval?,
        frames: [FeatureFrame],
        usedHitModel: Bool,
        for url: URL
    ) -> (baseline: SessionBaseline, run: Int)? {
        guard let vid = videoID(for: url) else { return nil }
        migrateLegacyLayout(forVideoID: vid)
        let run = (runNumbers(forVideoID: vid).last ?? 0) + 1
        let dir = runDirectory(forVideoID: vid, run: run)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var baseline = SessionBaseline()
        baseline.eventSeqAtSave = nextSeq(forVideoID: vid)
        baseline.videoDuration = videoDuration
        baseline.segments = segments
        baseline.games = games
        baseline.serveSides = serveSides

        guard writeBaseline(baseline, toDirectory: dir) else { return nil }

        // Frames cache (compact; a few MB at most)
        let codable = frames.map(CodableFrame.init(from:))
        if let framesData = try? Self.ledgerEncoder.encode(codable) {
            try? framesData.write(to: dir.appendingPathComponent("frames.json"))
        }

        // Meta
        let sessionDir = sessionDirectory(forVideoID: vid)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
        let meta = SessionMeta(videoID: vid, fileName: url.lastPathComponent, fileSize: fileSize, lastOpened: Date())
        if let metaData = try? Self.prettyEncoder.encode(meta) {
            try? metaData.write(to: sessionDir.appendingPathComponent("meta.json"))
        }

        setCurrentRun(run, forVideoID: vid)
        let pointCount = games.reduce(0) { $0 + $1.points.count }
        append(.analysisRun(pointCount: pointCount, usedHitModel: usedHitModel), for: url, run: run)
        return (baseline, run)
    }

    /// Persist the per-video audio signals into a run's directory.
    func saveAudioSignals(_ signals: AudioSignals, for url: URL, run: Int? = nil) {
        guard let vid = videoID(for: url),
              let targetRun = run ?? currentRun(forVideoID: vid) else { return }
        let dir = runDirectory(forVideoID: vid, run: targetRun)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Self.ledgerEncoder.encode(signals) {
            try? data.write(to: dir.appendingPathComponent("audio.json"))
        }
    }

    /// Overwrite a run's baseline in place (e.g. when async serve detection
    /// finishes after the baseline was first saved). Does not touch the ledger.
    func rewriteBaseline(_ baseline: SessionBaseline, for url: URL, run: Int? = nil) {
        guard let vid = videoID(for: url),
              let targetRun = run ?? currentRun(forVideoID: vid) else { return }
        _ = writeBaseline(baseline, toDirectory: runDirectory(forVideoID: vid, run: targetRun))
    }

    private func writeBaseline(_ baseline: SessionBaseline, toDirectory dir: URL) -> Bool {
        guard let data = try? Self.prettyEncoder.encode(baseline) else { return false }
        return (try? data.write(to: dir.appendingPathComponent("baseline.json"))) != nil
    }

    // MARK: - Load

    /// Load a session at a specific run (nil = the current run).
    func loadSession(for url: URL, run: Int? = nil) -> LoadedSession? {
        guard let vid = videoID(for: url) else { return nil }
        migrateLegacyLayout(forVideoID: vid)
        guard let targetRun = run ?? currentRun(forVideoID: vid),
              let session = loadRun(videoID: vid, run: targetRun) else { return nil }

        // Touch lastOpened
        let dir = sessionDirectory(forVideoID: vid)
        if var meta = try? Self.decoder.decode(SessionMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))) {
            meta.lastOpened = Date()
            if let metaData = try? Self.prettyEncoder.encode(meta) {
                try? metaData.write(to: dir.appendingPathComponent("meta.json"))
            }
        }
        return session
    }

    /// Load one run's full state by videoID (also used by the shadow-eval
    /// corpus and the ranker's rating pool).
    func loadRun(videoID vid: String, run: Int) -> LoadedSession? {
        guard let baseline = loadBaseline(forVideoID: vid, run: run),
              !baseline.games.isEmpty else { return nil }
        let dir = runDirectory(forVideoID: vid, run: run)

        var frames: [FeatureFrame] = []
        if let framesData = try? Data(contentsOf: dir.appendingPathComponent("frames.json")),
           let codable = try? Self.decoder.decode([CodableFrame].self, from: framesData) {
            frames = codable.map { $0.toFeatureFrame() }
        }

        let audioSignals = (try? Data(contentsOf: dir.appendingPathComponent("audio.json")))
            .flatMap { try? Self.decoder.decode(AudioSignals.self, from: $0) }

        return LoadedSession(
            run: run,
            baseline: baseline,
            events: ledgerEntries(forVideoID: vid, run: run).map(\.event),
            frames: frames,
            audioSignals: audioSignals
        )
    }

    /// All videoIDs that have at least one run on disk.
    func allVideoIDs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }
}
