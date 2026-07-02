import XCTest
@testable import DeltaCore

final class RepositorySecretAccessRepairerTests: XCTestCase {
    func testAccountsIncludeRepositoryPasswordAndBackendCredentials() {
        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "delta", path: nil, region: nil),
            keychainAccount: "repository-password",
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_ACCESS_KEY_ID", keychainAccount: "access-key"),
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "secret-key")
            ]
        )

        let accounts = RepositorySecretAccessRepairer.accounts(for: repository)

        XCTAssertEqual(accounts.map(\.account), ["repository-password", "access-key", "secret-key"])
        XCTAssertEqual(accounts.map(\.purpose), [
            "Destination encryption password",
            "Backend credential AWS_ACCESS_KEY_ID",
            "Backend credential AWS_SECRET_ACCESS_KEY"
        ])
    }

    func testVerifyReportsAccountsThatCannotBeReadWithoutInteraction() throws {
        let secrets = RepairableSecretStore()
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"), keychainAccount: "repo")
        try secrets.saveInitial("password", account: "repo", backgroundReadable: false)

        let report = secrets.repairer.verify(repository: repository)

        XCTAssertEqual(report.checkedAccounts, 1)
        XCTAssertEqual(report.repairedAccounts, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.account, "repo")
    }

    func testRepairRewritesSecretsAndVerifiesBackgroundReadableAccess() throws {
        let secrets = RepairableSecretStore()
        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "delta", path: nil, region: nil),
            keychainAccount: "repo",
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "secret-key")
            ]
        )
        try secrets.saveInitial("password", account: "repo", backgroundReadable: false)
        try secrets.saveInitial("backend-secret", account: "secret-key", backgroundReadable: false)

        let report = secrets.repairer.repair(repository: repository)

        XCTAssertTrue(report.isFullyAccessible)
        XCTAssertEqual(report.checkedAccounts, 2)
        XCTAssertEqual(report.repairedAccounts, 2)
        XCTAssertTrue(secrets.isBackgroundReadable(account: "repo"))
        XCTAssertTrue(secrets.isBackgroundReadable(account: "secret-key"))
    }

    func testRepairKeepsFailureScopedToTheFailingAccount() throws {
        let secrets = RepairableSecretStore()
        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "delta", path: nil, region: nil),
            keychainAccount: "repo",
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "missing-secret")
            ]
        )
        try secrets.saveInitial("password", account: "repo", backgroundReadable: false)

        let report = secrets.repairer.repair(repository: repository)

        XCTAssertFalse(report.isFullyAccessible)
        XCTAssertEqual(report.checkedAccounts, 2)
        XCTAssertEqual(report.repairedAccounts, 1)
        XCTAssertEqual(report.failures.map(\.account), ["missing-secret"])
    }

    func testCleanerDeletesDestinationPasswordAndBackendCredentialsOnce() {
        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "delta", path: nil, region: nil),
            keychainAccount: "repo",
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_ACCESS_KEY_ID", keychainAccount: "access-key"),
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "secret-key"),
                RepositoryCredentialReference(environmentKey: "DUPLICATE", keychainAccount: "secret-key")
            ]
        )
        let recorder = SecretCleanupRecorder()
        let cleaner = RepositorySecretCleaner { account in
            recorder.delete(account: account)
        }

        let report = cleaner.cleanup(repository: repository)

        XCTAssertTrue(report.isFullyCleaned)
        XCTAssertEqual(report.checkedAccounts, 3)
        XCTAssertEqual(report.deletedAccounts, 3)
        XCTAssertEqual(recorder.deletedAccounts, ["repo", "access-key", "secret-key"])
    }

    func testCleanerReportsFailuresAndContinuesDeletingOtherAccounts() {
        enum TestError: Error {
            case deleteFailed
        }

        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "delta", path: nil, region: nil),
            keychainAccount: "repo",
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_ACCESS_KEY_ID", keychainAccount: "broken-key"),
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "secret-key")
            ]
        )
        let recorder = SecretCleanupRecorder(failingAccount: "broken-key")
        let cleaner = RepositorySecretCleaner { account in
            try recorder.delete(account: account, error: TestError.deleteFailed)
        }

        let report = cleaner.cleanup(repository: repository)

        XCTAssertFalse(report.isFullyCleaned)
        XCTAssertEqual(report.checkedAccounts, 3)
        XCTAssertEqual(report.deletedAccounts, 2)
        XCTAssertEqual(report.failures.map(\.account), ["broken-key"])
        XCTAssertEqual(report.failures.map(\.purpose), ["Backend credential AWS_ACCESS_KEY_ID"])
        XCTAssertEqual(recorder.deletedAccounts, ["repo", "secret-key"])
    }
}

private final class RepairableSecretStore: @unchecked Sendable {
    private var values: [String: String] = [:]
    private var backgroundReadableAccounts = Set<String>()
    private let lock = NSLock()

    var repairer: RepositorySecretAccessRepairer {
        RepositorySecretAccessRepairer(
            loadInteractive: { account in
                try self.load(account: account, requireBackgroundReadable: false)
            },
            saveInteractive: { secret, account in
                try self.save(secret, account: account, backgroundReadable: true)
            },
            loadBackground: { account in
                try self.load(account: account, requireBackgroundReadable: true)
            }
        )
    }

    func saveInitial(_ secret: String, account: String, backgroundReadable: Bool) throws {
        try save(secret, account: account, backgroundReadable: backgroundReadable)
    }

    func isBackgroundReadable(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundReadableAccounts.contains(account)
    }

    private func save(_ secret: String, account: String, backgroundReadable: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = secret
        if backgroundReadable {
            backgroundReadableAccounts.insert(account)
        } else {
            backgroundReadableAccounts.remove(account)
        }
    }

    private func load(account: String, requireBackgroundReadable: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[account] else {
            throw KeychainSecretError.itemNotFound
        }
        if requireBackgroundReadable && !backgroundReadableAccounts.contains(account) {
            throw KeychainSecretError.interactionNotAllowed
        }
        return value
    }
}

private final class SecretCleanupRecorder: @unchecked Sendable {
    private let failingAccount: String?
    private var deleted: [String] = []
    private let lock = NSLock()

    init(failingAccount: String? = nil) {
        self.failingAccount = failingAccount
    }

    var deletedAccounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deleted
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        deleted.append(account)
    }

    func delete(account: String, error: Error) throws {
        lock.lock()
        defer { lock.unlock() }
        if account == failingAccount {
            throw error
        }
        deleted.append(account)
    }
}
