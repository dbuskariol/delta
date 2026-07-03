import Foundation

public struct LocalResticRepositoryState: Equatable, Sendable {
    public var path: String
    public var isPrepared: Bool

    public init(path: String, isPrepared: Bool) {
        self.path = path
        self.isPrepared = isPrepared
    }
}

public struct LocalResticRepositoryStateInspector: Sendable {
    public init() {}

    public func state(for backend: RepositoryBackend) -> LocalResticRepositoryState? {
        guard case let .local(path) = backend else {
            return nil
        }
        return state(path: path)
    }

    public func state(path: String) -> LocalResticRepositoryState {
        let expandedPath = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let configPath = URL(fileURLWithPath: expandedPath).appendingPathComponent("config").path
        return LocalResticRepositoryState(
            path: expandedPath,
            isPrepared: FileManager.default.fileExists(atPath: configPath)
        )
    }
}
