import Foundation

struct ModelManifest: Codable {
    var formatVersion: String
    var modelId: String
    var modelVersion: String
    var framework: String
    var entryFile: String
    var sha256: String
}
