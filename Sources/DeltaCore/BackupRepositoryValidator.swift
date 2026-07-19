import Foundation

public enum BackupRepositoryValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyField(String)
    case relativeLocalPath(String)
    case localDestinationUnavailable(String)
    case invalidSFTPPath(String)
    case invalidSFTPIdentityFile(String)
    case invalidPort(Int)
    case invalidURL(String)
    case invalidRcloneRemote(String)
    case timeMachineUnsupportedBackend(RepositoryBackendKind)
    case invalidTimeMachineVolumeName(String)
    case invalidTimeMachineImageCapacity(Int64)
    case invalidTimeMachineCacheLimit(Int64)

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
        case let .invalidSFTPIdentityFile(path):
            "Choose a readable local SSH private key file, not '\(path)'."
        case let .invalidPort(port):
            "Use a destination port from 1 to 65535, not \(port)."
        case let .invalidURL(value):
            "Enter a valid http or https URL, not '\(value)'."
        case let .invalidRcloneRemote(remote):
            "Enter the rclone remote name without a colon, not '\(remote)'."
        case let .timeMachineUnsupportedBackend(kind):
            "\(kind.displayName) cannot safely store a Time Machine disk. Choose an object-capable or filesystem destination."
        case let .invalidTimeMachineVolumeName(name):
            "Enter a Time Machine disk name from 1 to 63 characters without '/' or ':', not '\(name)'."
        case let .invalidTimeMachineImageCapacity(bytes):
            "Choose a Time Machine disk capacity from 256 MiB to 64 TiB. The entered byte count is \(bytes)."
        case let .invalidTimeMachineCacheLimit(bytes):
            "Choose a Time Machine cache from 64 MiB to less than the disk capacity. The entered byte count is \(bytes)."
        }
    }
}

public struct BackupRepositoryValidationResult: Equatable, Sendable {
    public var name: String
    public var backend: RepositoryBackend
    public var format: BackupFormat
    public var timeMachineSettings: TimeMachineRepositorySettings?
}

public struct BackupRepositoryValidator: Sendable {
    public var availabilityChecker: RepositoryAvailabilityChecker

    public init(availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker()) {
        self.availabilityChecker = availabilityChecker
    }

    public func validate(
        name: String,
        backend: RepositoryBackend,
        format: BackupFormat = .delta,
        timeMachineSettings: TimeMachineRepositorySettings? = nil,
        validateLocalAvailability: Bool = true
    ) throws -> BackupRepositoryValidationResult {
        let trimmedName = trimmed(name)
        guard !trimmedName.isEmpty else {
            throw BackupRepositoryValidationError.emptyName
        }

        let normalizedBackend = try normalized(backend)
        let normalizedTimeMachineSettings: TimeMachineRepositorySettings?
        switch format {
        case .delta:
            normalizedTimeMachineSettings = nil
        case .timeMachine:
            guard normalizedBackend.kind.supportsTimeMachineObjectStorage else {
                throw BackupRepositoryValidationError.timeMachineUnsupportedBackend(normalizedBackend.kind)
            }
            normalizedTimeMachineSettings = try normalized(
                timeMachineSettings ?? TimeMachineRepositorySettings(volumeName: trimmedName)
            )
        }
        if validateLocalAvailability, case let .local(path) = normalizedBackend {
            let repository = BackupRepository(
                name: trimmedName,
                backend: .local(path: path),
                format: format,
                timeMachineSettings: normalizedTimeMachineSettings
            )
            guard availabilityChecker.isAvailable(repository) else {
                throw BackupRepositoryValidationError.localDestinationUnavailable(path)
            }
        }

        return BackupRepositoryValidationResult(
            name: trimmedName,
            backend: normalizedBackend,
            format: format,
            timeMachineSettings: normalizedTimeMachineSettings
        )
    }

    private func normalized(_ settings: TimeMachineRepositorySettings) throws -> TimeMachineRepositorySettings {
        guard let volumeName = TimeMachineRepositorySettings.normalizedVolumeName(
            settings.volumeName
        ) else {
            throw BackupRepositoryValidationError.invalidTimeMachineVolumeName(settings.volumeName)
        }

        let validCapacity = ClosedRange(
            uncheckedBounds: (
                TimeMachineRepositorySettings.minimumImageCapacityBytes,
                TimeMachineRepositorySettings.maximumImageCapacityBytes
            )
        )
        guard validCapacity.contains(settings.imageCapacityBytes) else {
            throw BackupRepositoryValidationError.invalidTimeMachineImageCapacity(settings.imageCapacityBytes)
        }

        let minimumCache = TimeMachineRepositorySettings.minimumCacheLimitBytes
        guard
            settings.cacheLimitBytes >= minimumCache,
            settings.cacheLimitBytes < settings.imageCapacityBytes
        else {
            throw BackupRepositoryValidationError.invalidTimeMachineCacheLimit(settings.cacheLimitBytes)
        }

        var normalized = settings
        normalized.volumeName = volumeName
        return normalized
    }

    private func normalized(_ backend: RepositoryBackend) throws -> RepositoryBackend {
        switch backend {
        case let .local(path):
            let expandedPath = (try required(path, field: "local folder") as NSString).expandingTildeInPath
            guard expandedPath.hasPrefix("/") else {
                throw BackupRepositoryValidationError.relativeLocalPath(path)
            }
            return .local(path: expandedPath)

        case let .sftp(host, path, username, port, identityFilePath):
            let host = try required(host, field: "SFTP host")
            let path = try required(path, field: "SFTP path")
            guard path.hasPrefix("/") else {
                throw BackupRepositoryValidationError.invalidSFTPPath(path)
            }
            try validatePort(port)
            let identityFilePath = try optionalReadableFilePath(identityFilePath)
            return .sftp(
                host: host,
                path: path,
                username: optional(username),
                port: port,
                identityFilePath: identityFilePath
            )

        case let .rest(url):
            let url = try required(url, field: "REST URL")
            try validateHTTPURL(url)
            return .rest(url: url)

        case let .s3(endpoint, bucket, path, region):
            return .s3(
                endpoint: try required(endpoint, field: "S3 endpoint"),
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

    private func required(_ value: String?, field: String) throws -> String {
        try required(value ?? "", field: field)
    }

    private func optional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalReadableFilePath(_ value: String?) throws -> String? {
        guard let value = optional(value) else {
            return nil
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.isReadableFile(atPath: expanded) else {
            throw BackupRepositoryValidationError.invalidSFTPIdentityFile(value)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BackupRepositoryValidationError.invalidSFTPIdentityFile(value)
        }
        return expanded
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
