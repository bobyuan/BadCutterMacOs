import Foundation
import CryptoKit

/// Per-video session persistence: an append-only correction ledger, the
/// analysis baseline, and a feature-frame cache, stored under
/// Application Support/BadmintonVideoCutter/sessions/<videoID>/
///
///   ledger.jsonl    append-only events, one JSON object per line
///   baseline.json   analysis output (segments, games, serve sides)
///   frames.json     cached FeatureFrames (CodableFrame array) for replay
///   meta.json       video identity + bookkeeping
final class SessionStore {
    static let shared = SessionStore()

    private let root: URL
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
        var baseline: SessionBaseline
        /// Events recorded after the baseline was saved, in ledger order.
        var events: [SessionEvent]
        var frames: [FeatureFrame]
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

    // MARK: - Ledger

    /// Append an event to the video's ledger. Returns the assigned seq.
    @discardableResult
    func append(_ event: SessionEvent, for url: URL) -> Int? {
        guard let vid = videoID(for: url) else { return nil }
        let dir = sessionDirectory(forVideoID: vid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")

        let seq = nextSeq(forVideoID: vid)
        let entry = LedgerEntry(seq: seq, ts: Date(), event: event)
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

    // MARK: - Baseline + Frames

    /// Persist a fresh analysis result as the new baseline (also records an
    /// analysisRun audit event and refreshes meta.json + frames cache).
    @discardableResult
    func saveBaseline(
        segments: [TimeSegment],
        games: [Game],
        serveSides: [UUID: ServeDetector.ServeSide],
        videoDuration: TimeInterval?,
        frames: [FeatureFrame],
        usedHitModel: Bool,
        for url: URL
    ) -> SessionBaseline? {
        guard let vid = videoID(for: url) else { return nil }
        let dir = sessionDirectory(forVideoID: vid)
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
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
        let meta = SessionMeta(videoID: vid, fileName: url.lastPathComponent, fileSize: fileSize, lastOpened: Date())
        if let metaData = try? Self.prettyEncoder.encode(meta) {
            try? metaData.write(to: dir.appendingPathComponent("meta.json"))
        }

        let pointCount = games.reduce(0) { $0 + $1.points.count }
        append(.analysisRun(pointCount: pointCount, usedHitModel: usedHitModel), for: url)
        return baseline
    }

    /// Overwrite baseline.json in place (e.g. when async serve detection
    /// finishes after the baseline was first saved). Does not touch the ledger.
    func rewriteBaseline(_ baseline: SessionBaseline, for url: URL) {
        guard let dir = sessionDirectory(for: url) else { return }
        _ = writeBaseline(baseline, toDirectory: dir)
    }

    private func writeBaseline(_ baseline: SessionBaseline, toDirectory dir: URL) -> Bool {
        guard let data = try? Self.prettyEncoder.encode(baseline) else { return false }
        return (try? data.write(to: dir.appendingPathComponent("baseline.json"))) != nil
    }

    // MARK: - Load

    func loadSession(for url: URL) -> LoadedSession? {
        guard let vid = videoID(for: url) else { return nil }
        let dir = sessionDirectory(forVideoID: vid)
        guard let baselineData = try? Data(contentsOf: dir.appendingPathComponent("baseline.json")),
              let baseline = try? Self.decoder.decode(SessionBaseline.self, from: baselineData) else {
            return nil
        }

        let events = loadLedger(forVideoID: vid)
            .filter { $0.seq >= baseline.eventSeqAtSave }
            .map(\.event)

        var frames: [FeatureFrame] = []
        if let framesData = try? Data(contentsOf: dir.appendingPathComponent("frames.json")),
           let codable = try? Self.decoder.decode([CodableFrame].self, from: framesData) {
            frames = codable.map { $0.toFeatureFrame() }
        }

        // Touch lastOpened
        if var meta = try? Self.decoder.decode(SessionMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))) {
            meta.lastOpened = Date()
            if let metaData = try? Self.prettyEncoder.encode(meta) {
                try? metaData.write(to: dir.appendingPathComponent("meta.json"))
            }
        }

        return LoadedSession(baseline: baseline, events: events, frames: frames)
    }
}
