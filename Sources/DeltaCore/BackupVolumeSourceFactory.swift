import Foundation

public struct BackupVolumeSourceFactory: Sendable {
    public init() {}

    public func startupVolumeSource() -> BackupSource {
        BackupSource(path: "/", bookmarkData: nil, includeSubvolumes: false)
    }

    public func selectedVolumeSource(from url: URL) -> BackupSource {
        return BackupSource(
            path: volumeRootPath(for: url),
            bookmarkData: nil,
            includeSubvolumes: false
        )
    }

    public func normalizedVolumePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded == "/" {
            return "/"
        }

        let withoutTrailingSlash = expanded.hasSuffix("/")
            ? String(expanded.dropLast())
            : expanded
        return withoutTrailingSlash.isEmpty ? "/" : withoutTrailingSlash
    }

    private func volumeRootPath(for url: URL) -> String {
        let selectedPath = normalizedVolumePath(url.path)
        guard selectedPath != "/" else {
            return "/"
        }
        guard selectedPath.hasPrefix("/Volumes/") else {
            return "/"
        }

        if let resolvedPath = resolvedVolumeURL(for: url).map({ normalizedVolumePath($0.path) }),
           resolvedPath.hasPrefix("/Volumes/") {
            return resolvedPath
        }

        let relativeVolumePath = selectedPath.dropFirst("/Volumes/".count)
        guard let volumeName = relativeVolumePath.split(separator: "/").first else {
            return "/"
        }
        return "/Volumes/\(volumeName)"
    }

    private func resolvedVolumeURL(for url: URL) -> URL? {
        do {
            return try url.resourceValues(forKeys: [.volumeURLKey]).allValues[.volumeURLKey] as? URL
        } catch {
            return nil
        }
    }
}
