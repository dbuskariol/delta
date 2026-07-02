import Foundation

public struct RepositoryCredentialResolver: Sendable {
    public var loadSecret: @Sendable (String) throws -> String
    public var saveSecret: @Sendable (String, String) throws -> Void
    public var deleteSecret: @Sendable (String) throws -> Void

    public init(
        secretStore: KeychainSecretStore = KeychainSecretStore(),
        authenticationPolicy: KeychainAuthenticationPolicy = .allowUserInteraction
    ) {
        self.loadSecret = { account in
            try secretStore.load(account: account, authenticationPolicy: authenticationPolicy)
        }
        self.saveSecret = { secret, account in
            try secretStore.save(secret: secret, account: account, authenticationPolicy: authenticationPolicy)
        }
        self.deleteSecret = { account in
            try secretStore.delete(account: account)
        }
    }

    public init(
        loadSecret: @escaping @Sendable (String) throws -> String,
        saveSecret: @escaping @Sendable (String, String) throws -> Void,
        deleteSecret: @escaping @Sendable (String) throws -> Void
    ) {
        self.loadSecret = loadSecret
        self.saveSecret = saveSecret
        self.deleteSecret = deleteSecret
    }

    public func environment(for repository: BackupRepository) throws -> [String: String] {
        var values: [String: String] = [:]
        for reference in repository.credentialReferences {
            let key = reference.environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = try loadSecret(reference.keychainAccount)
        }
        return values
    }

    public func saveCredentials(_ credentials: [String: String], repositoryID: UUID) throws -> [RepositoryCredentialReference] {
        var references: [RepositoryCredentialReference] = []
        do {
            for environmentKey in credentials.keys.sorted() {
                guard
                    !environmentKey.isEmpty,
                    let value = credentials[environmentKey],
                    !value.isEmpty
                else {
                    continue
                }
                let account = "repository-\(repositoryID.uuidString)-env-\(environmentKey)"
                try saveSecret(value, account)
                references.append(RepositoryCredentialReference(environmentKey: environmentKey, keychainAccount: account))
            }
        } catch {
            for reference in references {
                try? deleteSecret(reference.keychainAccount)
            }
            throw error
        }
        return references
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
        var rollbackItems: [CredentialRollbackItem] = []
        var touchedAccounts = Set<String>()

        do {
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

                let existing = existingByKey[key]
                let account = existing?.keychainAccount ?? "repository-\(repositoryID.uuidString)-env-\(key)"
                if touchedAccounts.insert(account).inserted {
                    rollbackItems.append(
                        CredentialRollbackItem(
                            account: account,
                            previousSecret: try existing.map { try loadSecret($0.keychainAccount) }
                        )
                    )
                }
                try saveSecret(value, account)
                updatedReferences.append(
                    RepositoryCredentialReference(
                        id: existing?.id ?? UUID(),
                        environmentKey: key,
                        keychainAccount: account
                    )
                )
            }

            let keptAccounts = Set(updatedReferences.map(\.keychainAccount))
            for oldReference in existingReferences where !keptAccounts.contains(oldReference.keychainAccount) {
                if touchedAccounts.insert(oldReference.keychainAccount).inserted {
                    rollbackItems.append(
                        CredentialRollbackItem(
                            account: oldReference.keychainAccount,
                            previousSecret: try loadSecret(oldReference.keychainAccount)
                        )
                    )
                }
                try deleteSecret(oldReference.keychainAccount)
            }
            return updatedReferences.sorted { $0.environmentKey < $1.environmentKey }
        } catch {
            for rollbackItem in rollbackItems.reversed() {
                rollbackItem.rollback(saveSecret: saveSecret, deleteSecret: deleteSecret)
            }
            throw error
        }
    }
}

private struct CredentialRollbackItem {
    var account: String
    var previousSecret: String?

    func rollback(
        saveSecret: @Sendable (String, String) throws -> Void,
        deleteSecret: @Sendable (String) throws -> Void
    ) {
        if let previousSecret {
            try? saveSecret(previousSecret, account)
        } else {
            try? deleteSecret(account)
        }
    }
}

public struct ResticBackendCredentialField: Identifiable, Equatable, Sendable {
    public var id: String { environmentKey }
    public var environmentKey: String
    public var title: String
    public var placeholder: String
    public var isSecret: Bool

    public init(
        environmentKey: String,
        title: String,
        placeholder: String = "",
        isSecret: Bool = true
    ) {
        self.environmentKey = environmentKey
        self.title = title
        self.placeholder = placeholder
        self.isSecret = isSecret
    }
}

public enum ResticBackendCredentialTemplates {
    public static func keys(for kind: RepositoryBackendKind) -> [String] {
        fields(for: kind).map(\.environmentKey)
    }

    public static func fields(for kind: RepositoryBackendKind) -> [ResticBackendCredentialField] {
        switch kind {
        case .rest:
            [
                field("RESTIC_REST_USERNAME", "Username", placeholder: "Optional", isSecret: false),
                field("RESTIC_REST_PASSWORD", "Password", placeholder: "REST server password")
            ]
        case .s3:
            [
                field("AWS_ACCESS_KEY_ID", "Access Key ID", placeholder: "AKIA...", isSecret: false),
                field("AWS_SECRET_ACCESS_KEY", "Secret Access Key", placeholder: "Secret key"),
                field("AWS_SESSION_TOKEN", "Session Token", placeholder: "Optional temporary token")
            ]
        case .backblazeB2:
            [
                field("B2_ACCOUNT_ID", "Account ID", isSecret: false),
                field("B2_ACCOUNT_KEY", "Application Key")
            ]
        case .azureBlob:
            [
                field("AZURE_ACCOUNT_NAME", "Account Name", isSecret: false),
                field("AZURE_ACCOUNT_KEY", "Account Key"),
                field("AZURE_ACCOUNT_SAS", "SAS Token"),
                field("AZURE_ENDPOINT_SUFFIX", "Endpoint Suffix", placeholder: "core.windows.net", isSecret: false)
            ]
        case .googleCloudStorage:
            [
                field("GOOGLE_PROJECT_ID", "Project ID", isSecret: false),
                field("GOOGLE_APPLICATION_CREDENTIALS", "Credentials File", placeholder: "/path/to/service-account.json", isSecret: false),
                field("GOOGLE_ACCESS_TOKEN", "Access Token")
            ]
        case .swiftObjectStorage:
            [
                field("OS_AUTH_URL", "Auth URL", placeholder: "https://identity.example.com/v3", isSecret: false),
                field("OS_REGION_NAME", "Region", isSecret: false),
                field("OS_USERNAME", "Username", isSecret: false),
                field("OS_USER_ID", "User ID", isSecret: false),
                field("OS_PASSWORD", "Password"),
                field("OS_TENANT_ID", "Tenant ID", isSecret: false),
                field("OS_TENANT_NAME", "Tenant Name", isSecret: false),
                field("OS_PROJECT_NAME", "Project Name", isSecret: false),
                field("OS_PROJECT_DOMAIN_NAME", "Project Domain", isSecret: false),
                field("OS_PROJECT_DOMAIN_ID", "Project Domain ID", isSecret: false),
                field("OS_USER_DOMAIN_NAME", "User Domain", isSecret: false),
                field("OS_USER_DOMAIN_ID", "User Domain ID", isSecret: false),
                field("OS_TRUST_ID", "Trust ID", isSecret: false),
                field("OS_APPLICATION_CREDENTIAL_ID", "Application Credential ID", isSecret: false),
                field("OS_APPLICATION_CREDENTIAL_NAME", "Application Credential Name", isSecret: false),
                field("OS_APPLICATION_CREDENTIAL_SECRET", "Application Credential Secret"),
                field("OS_STORAGE_URL", "Storage URL", isSecret: false),
                field("OS_AUTH_TOKEN", "Auth Token"),
                field("ST_AUTH", "Swift Auth URL", isSecret: false),
                field("ST_USER", "Swift User", isSecret: false),
                field("ST_KEY", "Swift Key"),
                field("SWIFT_DEFAULT_CONTAINER_POLICY", "Default Container Policy", isSecret: false)
            ]
        case .rclone:
            [
                field("RCLONE_CONFIG", "Config File", placeholder: "/Users/me/.config/rclone/rclone.conf", isSecret: false)
            ]
        default:
            []
        }
    }

    private static func field(
        _ environmentKey: String,
        _ title: String,
        placeholder: String = "",
        isSecret: Bool = true
    ) -> ResticBackendCredentialField {
        ResticBackendCredentialField(
            environmentKey: environmentKey,
            title: title,
            placeholder: placeholder,
            isSecret: isSecret
        )
    }
}
