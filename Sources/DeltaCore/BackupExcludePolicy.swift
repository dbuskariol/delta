import Foundation

public enum BackupExcludePolicy {
    public static let defaultMacOSExcludes: [String] = [
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.TemporaryItems",
        "/.Trashes",
        "/.DocumentRevisions-V100",
        "/.vol",
        "/Network",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/System/Volumes/VM",
        "/System/Volumes/Data/.Spotlight-V100",
        "/System/Volumes/Data/.fseventsd",
        "/private/var/db/DiagnosticMessages",
        "/private/var/db/uuidtext",
        "/private/var/folders/*/*/C",
        "/private/var/folders/*/*/T",
        "/private/var/tmp",
        "/tmp",
        "*/.DS_Store",
        "*/.Trash",
        "*/Library/Caches",
        "*/Library/Logs",
        "*/Library/Developer/Xcode/DerivedData",
        "*/Library/Containers/*/Data/Library/Caches",
        "*/node_modules",
        "*/.build",
        "*/target",
        "*/.git/objects/pack/tmp_*"
    ]

    public static func excludes(for profile: BackupProfile, repository: BackupRepository) -> [String] {
        var patterns = profile.excludePatterns
        if case let .local(path) = repository.backend {
            guard let absolutePath = normalizedLocalRepositoryPath(path) else {
                return Array(Set(patterns)).sorted()
            }
            patterns.append(absolutePath)
            patterns.append(absolutePath == "/" ? "/**" : "\(absolutePath)/**")
        }
        return Array(Set(patterns)).sorted()
    }

    private static func normalizedLocalRepositoryPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        guard expandedPath != "/" else {
            return "/"
        }

        let withoutTrailingSlashes = expandedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return expandedPath.hasPrefix("/") ? "/\(withoutTrailingSlashes)" : withoutTrailingSlashes
    }
}
