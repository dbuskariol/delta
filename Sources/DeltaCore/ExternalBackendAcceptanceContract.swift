import Foundation

public enum ExternalBackendAcceptanceError: Error, Equatable, LocalizedError {
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}

public enum AcceptanceExternalKind: String, CaseIterable, Sendable {
    case mounted
    case sftp
    case rest
    case s3
    case b2
    case azure
    case gcs
    case swift
    case rclone
    case custom

    public init(environmentValue: String?) throws {
        guard
            let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            let kind = AcceptanceExternalKind(rawValue: value)
        else {
            throw ExternalBackendAcceptanceError.validationFailed("DELTA_EXTERNAL_ACCEPTANCE_KIND must be mounted, sftp, rest, s3, b2, azure, gcs, swift, rclone, or custom.")
        }
        self = kind
    }

    public var displayName: String {
        switch self {
        case .mounted: "Mounted"
        case .sftp: "SFTP"
        case .rest: "REST"
        case .s3: "S3"
        case .b2: "Backblaze B2"
        case .azure: "Azure Blob"
        case .gcs: "Google Cloud Storage"
        case .swift: "OpenStack Swift"
        case .rclone: "rclone"
        case .custom: "Custom"
        }
    }

    public func backend(environment: [String: String]) throws -> RepositoryBackend {
        switch self {
        case .mounted:
            let path = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH",
                environment: environment
            )
            guard path.hasPrefix("/Volumes/") else {
                throw ExternalBackendAcceptanceError.validationFailed("Mounted acceptance repository must live under /Volumes.")
            }
            return .local(path: path)
        case .sftp:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_SFTP_REPOSITORY",
                environment: environment
            )
            return try sftpBackend(
                repository: repository,
                identityFilePath: environment["DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY"]
            )
        case .rest:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_REST_REPOSITORY",
                environment: environment
            )
            return try restBackend(repository: repository)
        case .s3:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_S3_REPOSITORY",
                environment: environment
            )
            return try s3Backend(
                repository: repository,
                region: environment["AWS_DEFAULT_REGION"]
            )
        case .b2:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_B2_REPOSITORY",
                environment: environment
            )
            return try b2Backend(repository: repository)
        case .azure:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_AZURE_REPOSITORY",
                environment: environment
            )
            return try azureBackend(repository: repository)
        case .gcs:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_GCS_REPOSITORY",
                environment: environment
            )
            return try gcsBackend(repository: repository)
        case .swift:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_SWIFT_REPOSITORY",
                environment: environment
            )
            return try swiftBackend(repository: repository)
        case .rclone:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_RCLONE_REPOSITORY",
                environment: environment
            )
            return try rcloneBackend(repository: repository)
        case .custom:
            let repository = try Self.requiredEnvironment(
                "DELTA_ACCEPTANCE_CUSTOM_REPOSITORY",
                environment: environment
            )
            return .custom(repository: repository)
        }
    }

    public func credentials(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        switch self {
        case .mounted, .sftp:
            return [:]
        case .rest:
            return credentials(for: .rest, environment: environment)
        case .s3:
            _ = try requiredCredential("AWS_ACCESS_KEY_ID", environment: environment)
            _ = try requiredCredential("AWS_SECRET_ACCESS_KEY", environment: environment)
            return credentials(for: .s3, environment: environment)
        case .b2:
            _ = try requiredCredential("B2_ACCOUNT_ID", environment: environment)
            _ = try requiredCredential("B2_ACCOUNT_KEY", environment: environment)
            return credentials(for: .backblazeB2, environment: environment)
        case .azure:
            _ = try requiredCredential("AZURE_ACCOUNT_NAME", environment: environment)
            try requireAnyCredential(["AZURE_ACCOUNT_KEY", "AZURE_ACCOUNT_SAS"], environment: environment)
            return credentials(for: .azureBlob, environment: environment)
        case .gcs:
            try requireAnyCredential(["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_ACCESS_TOKEN"], environment: environment)
            if let credentialsPath = optionalCredential("GOOGLE_APPLICATION_CREDENTIALS", environment: environment),
               !fileManager.isReadableFile(atPath: credentialsPath) {
                throw ExternalBackendAcceptanceError.validationFailed("GOOGLE_APPLICATION_CREDENTIALS is not readable: \(credentialsPath)")
            }
            return credentials(for: .googleCloudStorage, environment: environment)
        case .swift:
            let values = credentials(for: .swiftObjectStorage, environment: environment)
            let hasLegacyV1 = hasAll(["ST_AUTH", "ST_USER", "ST_KEY"], in: values)
            let hasPreauthenticatedStorageURL = hasAll(["OS_STORAGE_URL", "OS_AUTH_TOKEN"], in: values)
            let hasPasswordAuth = values["OS_AUTH_URL"] != nil
                && (values["OS_USERNAME"] != nil || values["OS_USER_ID"] != nil)
                && values["OS_PASSWORD"] != nil
            let hasApplicationCredentialAuth = values["OS_AUTH_URL"] != nil
                && (values["OS_APPLICATION_CREDENTIAL_ID"] != nil || values["OS_APPLICATION_CREDENTIAL_NAME"] != nil)
                && values["OS_APPLICATION_CREDENTIAL_SECRET"] != nil
            guard hasLegacyV1 || hasPreauthenticatedStorageURL || hasPasswordAuth || hasApplicationCredentialAuth else {
                throw ExternalBackendAcceptanceError.validationFailed("OpenStack Swift acceptance requires ST_AUTH/ST_USER/ST_KEY, OS_STORAGE_URL/OS_AUTH_TOKEN, Keystone password auth, or Keystone application credential auth.")
            }
            return values
        case .rclone:
            let configPath = try requiredCredential("RCLONE_CONFIG", environment: environment)
            if !fileManager.isReadableFile(atPath: configPath) {
                throw ExternalBackendAcceptanceError.validationFailed("RCLONE_CONFIG is not readable: \(configPath)")
            }
            return credentials(for: .rclone, environment: environment)
        case .custom:
            return try customCredentials(environment: environment)
        }
    }

    public func sftpBackend(repository: String, identityFilePath: String?) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sftp:") else {
            throw ExternalBackendAcceptanceError.validationFailed("SFTP acceptance repository must start with sftp:.")
        }
        if trimmed.hasPrefix("sftp://") {
            guard let components = URLComponents(string: trimmed), let host = components.host else {
                throw ExternalBackendAcceptanceError.validationFailed("Invalid SFTP URL: \(trimmed)")
            }
            let path = normalizedSFTPPath(components.path)
            return .sftp(
                host: host,
                path: path,
                username: components.user,
                port: components.port,
                identityFilePath: identityFilePath
            )
        }

        let remainder = String(trimmed.dropFirst("sftp:".count))
        guard let separator = remainder.range(of: ":/") else {
            throw ExternalBackendAcceptanceError.validationFailed("SFTP acceptance repository must include an absolute path.")
        }
        let hostPart = String(remainder[..<separator.lowerBound])
        let path = "/" + String(remainder[separator.upperBound...])
        let userAndHost = hostPart.split(separator: "@", maxSplits: 1).map(String.init)
        let username = userAndHost.count == 2 ? userAndHost[0] : nil
        let host = userAndHost.count == 2 ? userAndHost[1] : userAndHost[0]
        guard !host.isEmpty else {
            throw ExternalBackendAcceptanceError.validationFailed("SFTP acceptance repository host is empty.")
        }
        return .sftp(
            host: host,
            path: path,
            username: username,
            port: nil,
            identityFilePath: identityFilePath
        )
    }

    private func s3Backend(repository: String, region: String?) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("s3:") else {
            throw ExternalBackendAcceptanceError.validationFailed("S3 acceptance repository must start with s3:.")
        }
        let value = String(trimmed.dropFirst("s3:".count))
        guard let components = URLComponents(string: value), let scheme = components.scheme, let host = components.host else {
            throw ExternalBackendAcceptanceError.validationFailed("S3 acceptance repository must include an endpoint URL, bucket, and path.")
        }
        let endpoint = "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")"
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let bucket = parts.first, !bucket.isEmpty else {
            throw ExternalBackendAcceptanceError.validationFailed("S3 acceptance repository path must include a bucket.")
        }
        let path = parts.dropFirst().joined(separator: "/")
        return .s3(
            endpoint: endpoint,
            bucket: bucket,
            path: path.isEmpty ? nil : path,
            region: region
        )
    }

    private func restBackend(repository: String) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.hasPrefix("rest:") ? String(trimmed.dropFirst("rest:".count)) : trimmed
        guard
            let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host?.isEmpty == false
        else {
            throw ExternalBackendAcceptanceError.validationFailed("REST acceptance repository must be rest:https://host/path or https://host/path.")
        }
        return .rest(url: url)
    }

    private func b2Backend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "b2:", name: "Backblaze B2")
        return .backblazeB2(bucket: parts.container, path: parts.path)
    }

    private func azureBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "azure:", name: "Azure Blob")
        return .azureBlob(container: parts.container, path: parts.path)
    }

    private func gcsBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "gs:", name: "Google Cloud Storage")
        return .googleCloudStorage(bucket: parts.container, path: parts.path)
    }

    private func swiftBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "swift:", name: "OpenStack Swift")
        return .swiftObjectStorage(container: parts.container, path: parts.path)
    }

    private func rcloneBackend(repository: String) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rclone:") else {
            throw ExternalBackendAcceptanceError.validationFailed("rclone acceptance repository must start with rclone:.")
        }
        let remainder = String(trimmed.dropFirst("rclone:".count))
        guard let separator = remainder.firstIndex(of: ":") else {
            throw ExternalBackendAcceptanceError.validationFailed("rclone acceptance repository must be rclone:remote:path.")
        }
        let remote = String(remainder[..<separator])
        let path = String(remainder[remainder.index(after: separator)...])
        guard !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalBackendAcceptanceError.validationFailed("rclone acceptance repository must include a remote and path.")
        }
        return .rclone(remote: remote, path: path)
    }

    private func objectStoreParts(repository: String, prefix: String, name: String) throws -> (container: String, path: String?) {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            throw ExternalBackendAcceptanceError.validationFailed("\(name) acceptance repository must start with \(prefix).")
        }
        let remainder = String(trimmed.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":") else {
            throw ExternalBackendAcceptanceError.validationFailed("\(name) acceptance repository must include a bucket/container and path separator.")
        }
        let container = String(remainder[..<separator])
        let rawPath = String(remainder[remainder.index(after: separator)...])
        guard !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalBackendAcceptanceError.validationFailed("\(name) acceptance repository bucket/container is empty.")
        }
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (container, path.isEmpty ? nil : path)
    }

    private func normalizedSFTPPath(_ path: String) -> String {
        if path.hasPrefix("//") {
            return String(path.dropFirst())
        }
        return path.isEmpty ? "/" : path
    }

    private func credentials(for kind: RepositoryBackendKind, environment: [String: String]) -> [String: String] {
        ResticBackendCredentialTemplates.keys(for: kind).reduce(into: [:]) { result, key in
            if let value = optionalCredential(key, environment: environment) {
                result[key] = value
            }
        }
    }

    private func customCredentials(environment: [String: String]) throws -> [String: String] {
        let keys = (environment["DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return try keys.reduce(into: [:]) { result, key in
            result[key] = try requiredCredential(key, environment: environment)
        }
    }

    private func optionalCredential(_ key: String, environment: [String: String]) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func requiredCredential(_ key: String, environment: [String: String]) throws -> String {
        guard let value = optionalCredential(key, environment: environment) else {
            throw ExternalBackendAcceptanceError.validationFailed("\(key) is required.")
        }
        return value
    }

    private func requireAnyCredential(_ keys: [String], environment: [String: String]) throws {
        if keys.contains(where: { optionalCredential($0, environment: environment) != nil }) {
            return
        }
        throw ExternalBackendAcceptanceError.validationFailed("One of \(keys.joined(separator: ", ")) is required.")
    }

    private func hasAll(_ keys: [String], in values: [String: String]) -> Bool {
        keys.allSatisfy { values[$0] != nil }
    }

    private static func requiredEnvironment(_ key: String, environment: [String: String]) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ExternalBackendAcceptanceError.validationFailed("\(key) is required.")
        }
        return value
    }
}
