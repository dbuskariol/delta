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
            let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let absolutePath = normalizedPath.isEmpty ? "/" : (path.hasPrefix("/") ? "/\(normalizedPath)" : normalizedPath)
            patterns.append(absolutePath)
            patterns.append(absolutePath == "/" ? "/**" : "\(absolutePath)/**")
        }
        return Array(Set(patterns)).sorted()
    }
}
