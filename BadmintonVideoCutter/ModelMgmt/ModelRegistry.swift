import Foundation

/// Metadata stored beside each model version (DESIGN §3.5).
struct ModelVersionMetadata: Codable, Identifiable, Equatable {
    var version: Int
    var trainedAt: Date
    var clipCount: Int
    var trainingAccuracy: Double
    var shadowEval: ShadowEvalMetrics?
    var gateDecision: ShadowEval.GateDecision?
    var promoted: Bool
    var notes: String?

    var id: Int { version }

    var versionLabel: String { String(format: "v%03d", version) }
}

/// Versioned on-disk model store:
///
///   <root>/<modelName>/
///     v001/ model.mlmodelc  metadata.json
///     v002/ ...
///     current.json          # {"version": 2}
///
/// The "current" pointer decides which version analysis uses; promote/revert
/// just rewrites the pointer.
final class ModelRegistry {
    let modelName: String
    private let root: URL

    private struct CurrentPointer: Codable { var version: Int }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(modelName: String, rootDirectory: URL? = nil) {
        self.modelName = modelName
        if let rootDirectory {
            root = rootDirectory.appendingPathComponent(modelName)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport
                .appendingPathComponent("BadmintonVideoCutter")
                .appendingPathComponent("models")
                .appendingPathComponent(modelName)
        }
    }

    // MARK: - Paths

    private func versionDirectory(_ version: Int) -> URL {
        root.appendingPathComponent(String(format: "v%03d", version))
    }

    func modelURL(forVersion version: Int) -> URL {
        versionDirectory(version).appendingPathComponent("model.mlmodelc")
    }

    private var currentPointerURL: URL { root.appendingPathComponent("current.json") }

    // MARK: - Queries

    /// All versions, ascending.
    func versions() -> [ModelVersionMetadata] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix("v") }
            .compactMap { name -> ModelVersionMetadata? in
                let metaURL = root.appendingPathComponent(name).appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metaURL) else { return nil }
                return try? Self.decoder.decode(ModelVersionMetadata.self, from: data)
            }
            .sorted { $0.version < $1.version }
    }

    func metadata(forVersion version: Int) -> ModelVersionMetadata? {
        let metaURL = versionDirectory(version).appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? Self.decoder.decode(ModelVersionMetadata.self, from: data)
    }

    func currentVersion() -> Int? {
        guard let data = try? Data(contentsOf: currentPointerURL),
              let pointer = try? Self.decoder.decode(CurrentPointer.self, from: data) else { return nil }
        return FileManager.default.fileExists(atPath: modelURL(forVersion: pointer.version).path)
            ? pointer.version
            : nil
    }

    /// Compiled model the pipeline should use, or nil when nothing is promoted.
    func currentModelURL() -> URL? {
        currentVersion().map(modelURL(forVersion:))
    }

    // MARK: - Mutations

    /// Register a freshly compiled model as the next version (moves the file
    /// into the registry). Does NOT promote it.
    @discardableResult
    func addVersion(
        compiledModelAt sourceURL: URL,
        clipCount: Int,
        trainingAccuracy: Double,
        notes: String? = nil
    ) throws -> ModelVersionMetadata {
        let fm = FileManager.default
        let next = (versions().last?.version ?? 0) + 1
        let dir = versionDirectory(next)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: sourceURL, to: modelURL(forVersion: next))

        let metadata = ModelVersionMetadata(
            version: next,
            trainedAt: Date(),
            clipCount: clipCount,
            trainingAccuracy: trainingAccuracy,
            shadowEval: nil,
            gateDecision: nil,
            promoted: false,
            notes: notes
        )
        try save(metadata)
        return metadata
    }

    func save(_ metadata: ModelVersionMetadata) throws {
        let metaURL = versionDirectory(metadata.version).appendingPathComponent("metadata.json")
        let data = try Self.encoder.encode(metadata)
        try data.write(to: metaURL)
    }

    /// Point "current" at a version and record the promoted flag on every
    /// version's metadata.
    func promote(version: Int) {
        guard FileManager.default.fileExists(atPath: modelURL(forVersion: version).path) else { return }
        if let data = try? Self.encoder.encode(CurrentPointer(version: version)) {
            try? data.write(to: currentPointerURL)
        }
        for var meta in versions() {
            meta.promoted = meta.version == version
            try? save(meta)
        }
    }

    /// Delete every version and the current pointer.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Legacy Migration

    /// Adopt the pre-registry flat model file (hit_classifier.mlmodelc next to
    /// the app-support root) as v001, promoted. No-op when the registry
    /// already has versions or no legacy file exists.
    func migrateLegacyModel(at legacyURL: URL) {
        let fm = FileManager.default
        guard versions().isEmpty, fm.fileExists(atPath: legacyURL.path) else { return }
        let trainedAt = (try? fm.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date) ?? Date()
        do {
            try fm.createDirectory(at: versionDirectory(1), withIntermediateDirectories: true)
            try fm.moveItem(at: legacyURL, to: modelURL(forVersion: 1))
            let metadata = ModelVersionMetadata(
                version: 1,
                trainedAt: trainedAt ?? Date(),
                clipCount: 0,
                trainingAccuracy: 0,
                shadowEval: nil,
                gateDecision: nil,
                promoted: true,
                notes: "Migrated from pre-registry model file."
            )
            try save(metadata)
            promote(version: 1)
        } catch {
            // Leave the legacy file in place; the caller's fallback still works.
        }
    }
}
