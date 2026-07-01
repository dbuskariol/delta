import Foundation

public struct RepositoryAvailabilityChecker: Sendable {
    public init() {}

    public func isAvailable(_ repository: BackupRepository) -> Bool {
        switch repository.backend {
        case let .local(path):
            return FileManager.default.isWritableFile(atPath: path) || FileManager.default.fileExists(atPath: path)
        default:
            return true
        }
    }
}
