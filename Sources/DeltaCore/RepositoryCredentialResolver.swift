import Foundation

public struct RepositoryCredentialResolver: Sendable {
    public var secretStore: KeychainSecretStore

    public init(secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    public func environment(for repository: BackupRepository) throws -> [String: String] {
        var values: [String: String] = [:]
        for reference in repository.credentialReferences {
            let key = reference.environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = try secretStore.load(account: reference.keychainAccount)
        }
        return values
    }

    public func saveCredentials(_ credentials: [String: String], repositoryID: UUID) throws -> [RepositoryCredentialReference] {
        var references: [RepositoryCredentialReference] = []
        for (environmentKey, value) in credentials where !environmentKey.isEmpty && !value.isEmpty {
            let account = "repository-\(repositoryID.uuidString)-env-\(environmentKey)"
            try secretStore.save(secret: value, account: account)
            references.append(RepositoryCredentialReference(environmentKey: environmentKey, keychainAccount: account))
        }
        return references.sorted { $0.environmentKey < $1.environmentKey }
    }
}

public enum ResticBackendCredentialTemplates {
    public static func keys(for kind: RepositoryBackendKind) -> [String] {
        switch kind {
        case .s3:
            ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
        case .backblazeB2:
            ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY"]
        case .azureBlob:
            ["AZURE_ACCOUNT_NAME", "AZURE_ACCOUNT_KEY"]
        case .googleCloudStorage:
            ["GOOGLE_PROJECT_ID", "GOOGLE_APPLICATION_CREDENTIALS"]
        case .swiftObjectStorage:
            ["OS_AUTH_URL", "OS_USERNAME", "OS_PASSWORD", "OS_REGION_NAME"]
        case .rclone:
            ["RCLONE_CONFIG"]
        default:
            []
        }
    }
}
