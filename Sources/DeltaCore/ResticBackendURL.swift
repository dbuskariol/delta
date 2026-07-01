import Foundation

public enum ResticBackendError: Error, Equatable, LocalizedError {
    case emptyRequiredField(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case let .emptyRequiredField(field): "Missing required repository field: \(field)."
        case let .invalidPath(path): "Invalid repository path: \(path)."
        }
    }
}

public struct ResticBackendURLBuilder: Sendable {
    public init() {}

    public func repositoryURL(for backend: RepositoryBackend) throws -> String {
        switch backend {
        case let .local(path):
            try require(path, "local path")
            return path

        case let .sftp(host, path, username, port):
            try require(host, "SFTP host")
            try require(path, "SFTP path")
            let userPrefix = username.map { "\($0)@" } ?? ""
            let portSuffix = port.map { ":\($0)" } ?? ""
            return "sftp:\(userPrefix)\(host)\(portSuffix):\(path)"

        case let .rest(url):
            try require(url, "REST URL")
            return "rest:\(url)"

        case let .s3(endpoint, bucket, path, _):
            try require(bucket, "S3 bucket")
            let prefix = normalizedObjectPath(path)
            if let endpoint, !endpoint.isEmpty {
                return "s3:\(endpoint)/\(bucket)\(prefix)"
            }
            return "s3:\(bucket)\(prefix)"

        case let .backblazeB2(bucket, path):
            try require(bucket, "Backblaze B2 bucket")
            return "b2:\(bucket):\(normalizedObjectPath(path, separator: "/"))"

        case let .azureBlob(container, path):
            try require(container, "Azure Blob container")
            return "azure:\(container):\(normalizedObjectPath(path, separator: "/"))"

        case let .googleCloudStorage(bucket, path):
            try require(bucket, "Google Cloud Storage bucket")
            return "gs:\(bucket):\(normalizedObjectPath(path, separator: "/"))"

        case let .swiftObjectStorage(container, path):
            try require(container, "OpenStack Swift container")
            return "swift:\(container):\(normalizedObjectPath(path, separator: "/"))"

        case let .rclone(remote, path):
            try require(remote, "rclone remote")
            return "rclone:\(remote):\(path)"

        case let .custom(repository):
            try require(repository, "custom repository URL")
            return repository
        }
    }

    private func require(_ value: String, _ field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ResticBackendError.emptyRequiredField(field)
        }
    }

    private func normalizedObjectPath(_ path: String?, separator: String = "/") -> String {
        guard let path, !path.isEmpty else { return "" }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return "\(separator)\(trimmed)"
    }
}
