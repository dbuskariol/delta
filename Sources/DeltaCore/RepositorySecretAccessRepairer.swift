import Foundation

public struct RepositorySecretAccount: Equatable, Sendable {
    public var account: String
    public var purpose: String

    public init(account: String, purpose: String) {
        self.account = account
        self.purpose = purpose
    }
}

public struct RepositorySecretAccessFailure: Equatable, Sendable {
    public var account: String
    public var purpose: String
    public var message: String

    public init(account: String, purpose: String, message: String) {
        self.account = account
        self.purpose = purpose
        self.message = message
    }
}

public struct RepositorySecretAccessReport: Equatable, Sendable {
    public var repositoryID: UUID
    public var repositoryName: String
    public var checkedAccounts: Int
    public var repairedAccounts: Int
    public var failures: [RepositorySecretAccessFailure]

    public init(
        repositoryID: UUID,
        repositoryName: String,
        checkedAccounts: Int,
        repairedAccounts: Int = 0,
        failures: [RepositorySecretAccessFailure] = []
    ) {
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.checkedAccounts = checkedAccounts
        self.repairedAccounts = repairedAccounts
        self.failures = failures
    }

    public var isFullyAccessible: Bool {
        failures.isEmpty
    }
}

public struct RepositorySecretAccessRepairer: Sendable {
    public var loadInteractive: @Sendable (String) throws -> String
    public var saveInteractive: @Sendable (String, String) throws -> Void
    public var loadBackground: @Sendable (String) throws -> String

    public init(
        secretStore: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.loadInteractive = { account in
            try secretStore.load(account: account, authenticationPolicy: .allowUserInteraction)
        }
        self.saveInteractive = { secret, account in
            try secretStore.save(secret: secret, account: account, authenticationPolicy: .allowUserInteraction)
        }
        self.loadBackground = { account in
            try secretStore.load(account: account, authenticationPolicy: .failIfInteractionNeeded)
        }
    }

    public init(
        loadInteractive: @escaping @Sendable (String) throws -> String,
        saveInteractive: @escaping @Sendable (String, String) throws -> Void,
        loadBackground: @escaping @Sendable (String) throws -> String
    ) {
        self.loadInteractive = loadInteractive
        self.saveInteractive = saveInteractive
        self.loadBackground = loadBackground
    }

    public func verify(repository: BackupRepository) -> RepositorySecretAccessReport {
        let accounts = Self.accounts(for: repository)
        var failures: [RepositorySecretAccessFailure] = []

        for account in accounts {
            do {
                _ = try loadBackground(account.account)
            } catch {
                failures.append(
                    RepositorySecretAccessFailure(
                        account: account.account,
                        purpose: account.purpose,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return RepositorySecretAccessReport(
            repositoryID: repository.id,
            repositoryName: repository.name,
            checkedAccounts: accounts.count,
            failures: failures
        )
    }

    public func repair(repository: BackupRepository) -> RepositorySecretAccessReport {
        let accounts = Self.accounts(for: repository)
        var repairedAccounts = 0
        var failures: [RepositorySecretAccessFailure] = []

        for account in accounts {
            do {
                let secret = try loadInteractive(account.account)
                try saveInteractive(secret, account.account)
                _ = try loadBackground(account.account)
                repairedAccounts += 1
            } catch {
                failures.append(
                    RepositorySecretAccessFailure(
                        account: account.account,
                        purpose: account.purpose,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return RepositorySecretAccessReport(
            repositoryID: repository.id,
            repositoryName: repository.name,
            checkedAccounts: accounts.count,
            repairedAccounts: repairedAccounts,
            failures: failures
        )
    }

    public static func accounts(for repository: BackupRepository) -> [RepositorySecretAccount] {
        var accounts = [
            RepositorySecretAccount(
                account: repository.keychainAccount,
                purpose: repository.format == .timeMachine
                    ? "Time Machine disk encryption password"
                    : "Destination encryption password"
            )
        ]
        if let manifestAccount = repository.timeMachineSettings?.manifestKeychainAccount {
            accounts.append(
                RepositorySecretAccount(
                    account: manifestAccount,
                    purpose: "Time Machine manifest authentication"
                )
            )
        }
        accounts.append(
            contentsOf: repository.credentialReferences.map {
                RepositorySecretAccount(
                    account: $0.keychainAccount,
                    purpose: "Backend credential \($0.environmentKey)"
                )
            }
        )
        return accounts
    }
}
