import Foundation

public struct RepositorySecretCleanupFailure: Equatable, Sendable {
    public var account: String
    public var purpose: String
    public var message: String

    public init(account: String, purpose: String, message: String) {
        self.account = account
        self.purpose = purpose
        self.message = message
    }
}

public struct RepositorySecretCleanupReport: Equatable, Sendable {
    public var checkedAccounts: Int
    public var deletedAccounts: Int
    public var failures: [RepositorySecretCleanupFailure]

    public init(
        checkedAccounts: Int,
        deletedAccounts: Int,
        failures: [RepositorySecretCleanupFailure] = []
    ) {
        self.checkedAccounts = checkedAccounts
        self.deletedAccounts = deletedAccounts
        self.failures = failures
    }

    public var isFullyCleaned: Bool {
        failures.isEmpty
    }
}

public struct RepositorySecretCleaner: Sendable {
    public var deleteSecret: @Sendable (String) throws -> Void

    public init(secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.deleteSecret = { account in
            try secretStore.delete(account: account)
        }
    }

    public init(deleteSecret: @escaping @Sendable (String) throws -> Void) {
        self.deleteSecret = deleteSecret
    }

    public func cleanup(repository: BackupRepository) -> RepositorySecretCleanupReport {
        let accounts = uniqueAccounts(for: repository)
        var deletedAccounts = 0
        var failures: [RepositorySecretCleanupFailure] = []

        for account in accounts {
            do {
                try deleteSecret(account.account)
                deletedAccounts += 1
            } catch {
                failures.append(
                    RepositorySecretCleanupFailure(
                        account: account.account,
                        purpose: account.purpose,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return RepositorySecretCleanupReport(
            checkedAccounts: accounts.count,
            deletedAccounts: deletedAccounts,
            failures: failures
        )
    }

    private func uniqueAccounts(for repository: BackupRepository) -> [RepositorySecretAccount] {
        var seenAccounts = Set<String>()
        var uniqueAccounts: [RepositorySecretAccount] = []
        for account in RepositorySecretAccessRepairer.accounts(for: repository) where seenAccounts.insert(account.account).inserted {
            uniqueAccounts.append(account)
        }
        return uniqueAccounts
    }
}
