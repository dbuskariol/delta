import Foundation

public struct RepositoryAvailabilityChecker: Sendable {
    public init() {}

    public func isAvailable(_ repository: BackupRepository, allowingCreation: Bool = true) -> Bool {
        switch repository.backend {
        case let .local(path):
            let expandedPath = (path as NSString).expandingTildeInPath
            let destinationURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
                return isDirectory.boolValue && canCreateAndRemoveProbeFile(in: destinationURL)
            }

            guard allowingCreation else {
                return false
            }

            let parentURL = destinationURL.deletingLastPathComponent()
            let parent = parentURL.path
            var parentIsDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDirectory)
                && parentIsDirectory.boolValue
                && canCreateAndRemoveProbeFile(in: parentURL)
        default:
            return true
        }
    }

    private func canCreateAndRemoveProbeFile(in directoryURL: URL) -> Bool {
        let probeURL = directoryURL.appendingPathComponent(".delta-write-probe-\(UUID().uuidString)", isDirectory: false)
        do {
            try Data("delta".utf8).write(to: probeURL, options: [.atomic])
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return false
        }
    }
}
