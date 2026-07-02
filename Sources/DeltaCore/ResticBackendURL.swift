import Foundation

public enum ResticBackendError: Error, Equatable, LocalizedError {
    case emptyRequiredField(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case let .emptyRequiredField(field): "Missing required destination field: \(field)."
        case let .invalidPath(path): "Invalid destination path: \(path)."
        }
    }
}

public struct ResticBackendURLBuilder: Sendable {
    public init() {}

    public func repositoryURL(for backend: RepositoryBackend) throws -> String {
        switch backend {
        case let .local(path):
            try require(path, "local path")
            return (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath

        case let .sftp(host, path, username, port):
            try require(host, "SFTP host")
            try require(path, "SFTP path")
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if port != nil || trimmedHost.contains(":") {
                let userPrefix = username.flatMap(sftpURLUser).map { "\($0)@" } ?? ""
                let portSuffix = port.map { ":\($0)" } ?? ""
                return "sftp://\(userPrefix)\(sftpURLHost(trimmedHost))\(portSuffix)\(sftpURLPath(trimmedPath))"
            }
            let userPrefix = username.map { "\($0)@" } ?? ""
            return "sftp:\(userPrefix)\(trimmedHost):\(trimmedPath)"

        case let .rest(url):
            try require(url, "REST URL")
            return "rest:\(url)"

        case let .s3(endpoint, bucket, path, _):
            try require(bucket, "S3 bucket")
            let prefix = normalizedObjectPath(path)
            if let endpoint, !endpoint.isEmpty {
                return "s3:\(normalizedEndpoint(endpoint))/\(bucket)\(prefix)"
            }
            return "s3:\(bucket)\(prefix)"

        case let .backblazeB2(bucket, path):
            try require(bucket, "Backblaze B2 bucket")
            return "b2:\(bucket):\(normalizedObjectPath(path, separator: ""))"

        case let .azureBlob(container, path):
            try require(container, "Azure Blob container")
            return "azure:\(container):\(normalizedObjectPath(path, separator: "/", emptyPath: "/"))"

        case let .googleCloudStorage(bucket, path):
            try require(bucket, "Google Cloud Storage bucket")
            return "gs:\(bucket):\(normalizedObjectPath(path, separator: "/", emptyPath: "/"))"

        case let .swiftObjectStorage(container, path):
            try require(container, "OpenStack Swift container")
            return "swift:\(container):\(normalizedObjectPath(path, separator: "/"))"

        case let .rclone(remote, path):
            try require(remote, "rclone remote")
            return "rclone:\(remote):\(path)"

        case let .custom(repository):
            try require(repository, "custom destination URL")
            return repository
        }
    }

    private func require(_ value: String, _ field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ResticBackendError.emptyRequiredField(field)
        }
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func normalizedObjectPath(_ path: String?, separator: String = "/", emptyPath: String = "") -> String {
        guard let path, !path.isEmpty else { return emptyPath }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return emptyPath }
        return "\(separator)\(trimmed)"
    }

    private func sftpURLHost(_ host: String) -> String {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return host
        }
        return host.contains(":") ? "[\(host)]" : host
    }

    private func sftpURLPath(_ path: String) -> String {
        "/\(path)"
    }

    private func sftpURLUser(_ username: String) -> String? {
        username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
    }
}
