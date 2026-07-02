import Foundation

public enum BackupRepositoryValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyField(String)
    case relativeLocalPath(String)
    case localDestinationUnavailable(String)
    case invalidSFTPPath(String)
    case invalidPort(Int)
    case invalidURL(String)
    case invalidRcloneRemote(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a destination name."
        case let .emptyField(field):
            "Enter a value for \(field)."
        case let .relativeLocalPath(path):
            "Use an absolute local destination path, not '\(path)'."
        case let .localDestinationUnavailable(path):
            "Delta cannot write to the local destination or its parent folder: \(path)."
        case let .invalidSFTPPath(path):
            "Use an absolute SFTP destination path, not '\(path)'."
        case let .invalidPort(port):
            "Use a destination port from 1 to 65535, not \(port)."
        case let .invalidURL(value):
            "Enter a valid http or https URL, not '\(value)'."
        case let .invalidRcloneRemote(remote):
            "Enter the rclone remote name without a colon, not '\(remote)'."
        }
    }
}

public struct BackupRepositoryValidationResult: Equatable, Sendable {
    public var name: String
    public var backend: RepositoryBackend
}

public struct BackupRepositoryValidator: Sendable {
    public var availabilityChecker: RepositoryAvailabilityChecker

    public init(availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker()) {
        self.availabilityChecker = availabilityChecker
    }

    public func validate(
        name: String,
        backend: RepositoryBackend,
        validateLocalAvailability: Bool = true
    ) throws -> BackupRepositoryValidationResult {
        let trimmedName = trimmed(name)
        guard !trimmedName.isEmpty else {
            throw BackupRepositoryValidationError.emptyName
        }

        let normalizedBackend = try normalized(backend)
        if validateLocalAvailability, case let .local(path) = normalizedBackend {
            let repository = BackupRepository(name: trimmedName, backend: .local(path: path))
            guard availabilityChecker.isAvailable(repository) else {
                throw BackupRepositoryValidationError.localDestinationUnavailable(path)
            }
        }

        return BackupRepositoryValidationResult(name: trimmedName, backend: normalizedBackend)
    }

    private func normalized(_ backend: RepositoryBackend) throws -> RepositoryBackend {
        switch backend {
        case let .local(path):
            let expandedPath = (try required(path, field: "local folder") as NSString).expandingTildeInPath
            guard expandedPath.hasPrefix("/") else {
                throw BackupRepositoryValidationError.relativeLocalPath(path)
            }
            return .local(path: expandedPath)

        case let .sftp(host, path, username, port):
            let host = try required(host, field: "SFTP host")
            let path = try required(path, field: "SFTP path")
            guard path.hasPrefix("/") else {
                throw BackupRepositoryValidationError.invalidSFTPPath(path)
            }
            try validatePort(port)
            return .sftp(
                host: host,
                path: path,
                username: optional(username),
                port: port
            )

        case let .rest(url):
            let url = try required(url, field: "REST URL")
            try validateHTTPURL(url)
            return .rest(url: url)

        case let .s3(endpoint, bucket, path, region):
            return .s3(
                endpoint: optional(endpoint),
                bucket: try required(bucket, field: "S3 bucket"),
                path: optional(path),
                region: optional(region)
            )

        case let .backblazeB2(bucket, path):
            return .backblazeB2(bucket: try required(bucket, field: "Backblaze B2 bucket"), path: optional(path))

        case let .azureBlob(container, path):
            return .azureBlob(container: try required(container, field: "Azure Blob container"), path: optional(path))

        case let .googleCloudStorage(bucket, path):
            return .googleCloudStorage(bucket: try required(bucket, field: "Google Cloud Storage bucket"), path: optional(path))

        case let .swiftObjectStorage(container, path):
            return .swiftObjectStorage(container: try required(container, field: "OpenStack Swift container"), path: optional(path))

        case let .rclone(remote, path):
            let remote = try required(remote, field: "rclone remote")
            guard !remote.contains(":") else {
                throw BackupRepositoryValidationError.invalidRcloneRemote(remote)
            }
            return .rclone(remote: remote, path: try required(path, field: "rclone path"))

        case let .custom(repository):
            return .custom(repository: try required(repository, field: "destination URL"))
        }
    }

    private func validatePort(_ port: Int?) throws {
        guard let port else {
            return
        }
        guard (1...65_535).contains(port) else {
            throw BackupRepositoryValidationError.invalidPort(port)
        }
    }

    private func validateHTTPURL(_ value: String) throws {
        guard
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host?.isEmpty == false
        else {
            throw BackupRepositoryValidationError.invalidURL(value)
        }
    }

    private func required(_ value: String, field: String) throws -> String {
        let trimmed = trimmed(value)
        guard !trimmed.isEmpty else {
            throw BackupRepositoryValidationError.emptyField(field)
        }
        return trimmed
    }

    private func optional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
