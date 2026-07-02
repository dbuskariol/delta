import Foundation

public enum BackupSourceAccessError: Error, Equatable, LocalizedError {
    case missing(path: String)
    case notFolder(path: String)
    case unreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case let .missing(path):
            return "Selected backup source is no longer available: \(path). Reconnect it or edit the backup profile."
        case let .notFolder(path):
            return "Selected backup source is not a folder: \(path). Edit the backup profile and choose a folder."
        case let .unreadable(path):
            return "Delta cannot read selected backup source: \(path). Check Full Disk Access, folder permissions, or edit the backup profile."
        }
    }
}

public struct BackupSourceAccessChecker: Sendable {
    public init() {}

    public func validate(_ sources: [BackupSource]) throws {
        for source in sources {
            try validate(source)
        }
    }

    public func validate(_ source: BackupSource) throws {
        let path = (source.path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw BackupSourceAccessError.missing(path: path)
        }
        guard isDirectory.boolValue else {
            throw BackupSourceAccessError.notFolder(path: path)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw BackupSourceAccessError.unreadable(path: path)
        }
    }
}
