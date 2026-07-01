import Foundation

public enum SecurityScopedBookmarkError: Error, LocalizedError {
    case cannotCreate(URL, String)
    case cannotResolve(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotCreate(url, reason): "Could not create persistent access for \(url.path): \(reason)"
        case let .cannotResolve(path): "Could not resolve persistent access for \(path)."
        }
    }
}

public struct ResolvedSecurityScopedURL {
    public var url: URL
    private var didStartAccessing: Bool

    public init(url: URL, didStartAccessing: Bool) {
        self.url = url
        self.didStartAccessing = didStartAccessing
    }

    public func stopAccessing() {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public struct SecurityScopedBookmarkStore: Sendable {
    public init() {}

    public func makeSource(from url: URL, includeSubvolumes: Bool) throws -> BackupSource {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            return BackupSource(path: url.path, bookmarkData: data, includeSubvolumes: includeSubvolumes)
        } catch {
            throw SecurityScopedBookmarkError.cannotCreate(url, error.localizedDescription)
        }
    }

    public func resolve(_ source: BackupSource) throws -> ResolvedSecurityScopedURL {
        guard let bookmarkData = source.bookmarkData else {
            let url = URL(fileURLWithPath: source.path)
            return ResolvedSecurityScopedURL(url: url, didStartAccessing: false)
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart || FileManager.default.fileExists(atPath: url.path) else {
            throw SecurityScopedBookmarkError.cannotResolve(source.path)
        }
        return ResolvedSecurityScopedURL(url: url, didStartAccessing: didStart)
    }
}
