import Foundation

public struct RepositoryAvailabilityChecker: Sendable {
    public var capacityProvider: @Sendable (URL) -> Int64?

    public init(
        capacityProvider: @escaping @Sendable (URL) -> Int64? = RepositoryAvailabilityChecker.defaultAvailableCapacityBytes
    ) {
        self.capacityProvider = capacityProvider
    }

    public func isAvailable(_ repository: BackupRepository, allowingCreation: Bool = true) -> Bool {
        switch repository.backend {
        case let .local(path):
            guard let checkURL = writableDirectoryURL(forLocalPath: path, allowingCreation: allowingCreation) else {
                return false
            }
            return canCreateAndRemoveProbeFile(in: checkURL)
        default:
            return true
        }
    }

    public func availableCapacityBytes(
        for repository: BackupRepository,
        allowingCreation: Bool = false
    ) -> Int64? {
        guard case let .local(path) = repository.backend,
              let checkURL = writableDirectoryURL(forLocalPath: path, allowingCreation: allowingCreation) else {
            return nil
        }
        return capacityProvider(checkURL)
    }

    public static func defaultAvailableCapacityBytes(for url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
                return importantCapacity
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func writableDirectoryURL(forLocalPath path: String, allowingCreation: Bool) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        let destinationURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? destinationURL : nil
        }

        guard allowingCreation else {
            return nil
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let parent = parentURL.path
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return nil
        }
        return parentURL
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
