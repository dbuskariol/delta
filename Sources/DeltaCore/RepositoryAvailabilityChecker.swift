import Foundation

public struct RepositoryAvailabilityChecker: Sendable {
    public init() {}

    public func isAvailable(_ repository: BackupRepository, allowingCreation: Bool = true) -> Bool {
        switch repository.backend {
        case let .local(path):
            let expandedPath = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
                return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: expandedPath)
            }

            guard allowingCreation else {
                return false
            }

            let parent = URL(fileURLWithPath: expandedPath).deletingLastPathComponent().path
            var parentIsDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDirectory)
                && parentIsDirectory.boolValue
                && FileManager.default.isWritableFile(atPath: parent)
        default:
            return true
        }
    }
}
