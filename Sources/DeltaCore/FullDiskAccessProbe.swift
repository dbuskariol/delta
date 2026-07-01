import Foundation

public struct FullDiskAccessStatus: Equatable, Sendable {
    public var hasLikelyFullDiskAccess: Bool
    public var readableProbePath: String?
    public var checkedPaths: [String]

    public init(hasLikelyFullDiskAccess: Bool, readableProbePath: String?, checkedPaths: [String]) {
        self.hasLikelyFullDiskAccess = hasLikelyFullDiskAccess
        self.readableProbePath = readableProbePath
        self.checkedPaths = checkedPaths
    }
}

public struct FullDiskAccessProbe: Sendable {
    public init() {}

    public func check(fileManager: FileManager = .default) -> FullDiskAccessStatus {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Safari",
            "\(home)/Library/Application Support/com.apple.TCC"
        ]

        for path in candidates where fileManager.isReadableFile(atPath: path) {
            return FullDiskAccessStatus(hasLikelyFullDiskAccess: true, readableProbePath: path, checkedPaths: candidates)
        }
        return FullDiskAccessStatus(hasLikelyFullDiskAccess: false, readableProbePath: nil, checkedPaths: candidates)
    }
}
