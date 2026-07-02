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

    public func updateCredentials(
        _ credentials: [String: String],
        existingReferences: [RepositoryCredentialReference],
        repositoryID: UUID,
        allowedKeys: [String]
    ) throws -> [RepositoryCredentialReference] {
        let existingByKey = Dictionary(uniqueKeysWithValues: existingReferences.map { ($0.environmentKey, $0) })
        let allowedKeys = allowedKeys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var updatedReferences: [RepositoryCredentialReference] = []

        for key in allowedKeys {
            let value = credentials[key] ?? ""
            let isBlank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank, let existing = existingByKey[key] {
                updatedReferences.append(existing)
                continue
            }
            guard !isBlank else {
                continue
            }

            let account = existingByKey[key]?.keychainAccount ?? "repository-\(repositoryID.uuidString)-env-\(key)"
            try secretStore.save(secret: value, account: account)
            updatedReferences.append(
                RepositoryCredentialReference(
                    id: existingByKey[key]?.id ?? UUID(),
                    environmentKey: key,
                    keychainAccount: account
                )
            )
        }

        let keptAccounts = Set(updatedReferences.map(\.keychainAccount))
        for oldReference in existingReferences where !keptAccounts.contains(oldReference.keychainAccount) {
            try secretStore.delete(account: oldReference.keychainAccount)
        }
        return updatedReferences.sorted { $0.environmentKey < $1.environmentKey }
    }
}

public enum ResticBackendCredentialTemplates {
    public static func keys(for kind: RepositoryBackendKind) -> [String] {
        switch kind {
        case .rest:
            ["RESTIC_REST_USERNAME", "RESTIC_REST_PASSWORD"]
        case .s3:
            ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
        case .backblazeB2:
            ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY"]
        case .azureBlob:
            ["AZURE_ACCOUNT_NAME", "AZURE_ACCOUNT_KEY", "AZURE_ACCOUNT_SAS", "AZURE_ENDPOINT_SUFFIX"]
        case .googleCloudStorage:
            ["GOOGLE_PROJECT_ID", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_ACCESS_TOKEN"]
        case .swiftObjectStorage:
            [
                "OS_AUTH_URL",
                "OS_REGION_NAME",
                "OS_USERNAME",
                "OS_PASSWORD",
                "OS_TENANT_ID",
                "OS_TENANT_NAME",
                "OS_PROJECT_NAME",
                "OS_PROJECT_DOMAIN_NAME",
                "OS_USER_DOMAIN_NAME",
                "OS_APPLICATION_CREDENTIAL_ID",
                "OS_APPLICATION_CREDENTIAL_SECRET",
                "OS_STORAGE_URL",
                "OS_AUTH_TOKEN",
                "ST_AUTH",
                "ST_USER",
                "ST_KEY"
            ]
        case .rclone:
            ["RCLONE_CONFIG", "RCLONE_BWLIMIT", "RCLONE_VERBOSE"]
        default:
            []
        }
    }
}
