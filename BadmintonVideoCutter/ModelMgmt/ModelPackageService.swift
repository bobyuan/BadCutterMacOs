import Foundation

final class ModelPackageService {
    func importModelPackage(from url: URL) throws {
        // TODO: unzip, validate manifest, verify checksum, stage locally.
        _ = url
    }

    func exportActiveModel(to url: URL) throws {
        // TODO: package active model to .btmodel file.
        _ = url
    }
}
