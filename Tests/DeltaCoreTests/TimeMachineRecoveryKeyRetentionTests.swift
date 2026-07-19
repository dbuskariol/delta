import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineRecoveryKeyRetentionTests: XCTestCase {
    func testCanonicalAccountNeedsNoCopy() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: fixture.canonicalAccount)
        fixture.values[fixture.canonicalAccount] = "disk-secret"

        let result = try fixture.preparer.prepare(repository: repository)

        XCTAssertEqual(
            result,
            TimeMachineRecoveryKeyRetention(
                retainedAccount: fixture.canonicalAccount,
                obsoleteAccount: nil
            )
        )
        XCTAssertTrue(fixture.savedAccounts.isEmpty)
    }

    func testLegacyAccountIsCopiedAndVerifiedUnderRemoteStoreIdentity() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")
        fixture.values[repository.keychainAccount] = "disk-secret"

        let result = try fixture.preparer.prepare(repository: repository)

        XCTAssertEqual(
            result,
            TimeMachineRecoveryKeyRetention(
                retainedAccount: fixture.canonicalAccount,
                obsoleteAccount: repository.keychainAccount
            )
        )
        XCTAssertEqual(fixture.values[fixture.canonicalAccount], "disk-secret")
        XCTAssertEqual(fixture.savedAccounts, [fixture.canonicalAccount])
    }

    func testMatchingCanonicalAccountIsRetainedWithoutOverwrite() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")
        fixture.values[repository.keychainAccount] = "disk-secret"
        fixture.values[fixture.canonicalAccount] = "disk-secret"

        let result = try fixture.preparer.prepare(repository: repository)

        XCTAssertEqual(result?.retainedAccount, fixture.canonicalAccount)
        XCTAssertEqual(result?.obsoleteAccount, repository.keychainAccount)
        XCTAssertTrue(fixture.savedAccounts.isEmpty)
    }

    func testConflictingCanonicalAccountStopsBeforeOverwrite() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")
        fixture.values[repository.keychainAccount] = "active-disk-secret"
        fixture.values[fixture.canonicalAccount] = "different-secret"

        XCTAssertThrowsError(try fixture.preparer.prepare(repository: repository)) { error in
            XCTAssertEqual(
                error as? TimeMachineRecoveryKeyRetentionError,
                .conflictingSavedKey
            )
        }
        XCTAssertEqual(fixture.values[fixture.canonicalAccount], "different-secret")
        XCTAssertTrue(fixture.savedAccounts.isEmpty)
    }

    func testMissingActiveKeyStopsBeforeCreatingCanonicalAccount() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")

        XCTAssertThrowsError(try fixture.preparer.prepare(repository: repository)) { error in
            XCTAssertEqual(
                error as? TimeMachineRecoveryKeyRetentionError,
                .missingSavedKey
            )
        }
        XCTAssertNil(fixture.values[fixture.canonicalAccount])
        XCTAssertTrue(fixture.savedAccounts.isEmpty)
    }

    func testFailedCopyVerificationStopsRemoval() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")
        fixture.values[repository.keychainAccount] = "disk-secret"
        fixture.savedValueOverride = "corrupted-copy"

        XCTAssertThrowsError(try fixture.preparer.prepare(repository: repository)) { error in
            XCTAssertEqual(
                error as? TimeMachineRecoveryKeyRetentionError,
                .copyVerificationFailed
            )
        }
        XCTAssertNil(fixture.values[fixture.canonicalAccount])
        XCTAssertEqual(fixture.deletedAccounts, [fixture.canonicalAccount])
    }

    func testFailedCopyRollbackReportsTheIncompleteKeychainState() throws {
        let fixture = RecoveryKeyFixture()
        let repository = fixture.repository(keychainAccount: "legacy-repository-account")
        fixture.values[repository.keychainAccount] = "disk-secret"
        fixture.savedValueOverride = "corrupted-copy"
        fixture.deleteShouldFail = true

        XCTAssertThrowsError(try fixture.preparer.prepare(repository: repository)) { error in
            XCTAssertEqual(
                error as? TimeMachineRecoveryKeyRetentionError,
                .copyRollbackFailed
            )
        }
        XCTAssertEqual(fixture.values[fixture.canonicalAccount], "corrupted-copy")
    }

    func testUserManagedPasswordDoesNotCreateRetainedAccount() throws {
        let fixture = RecoveryKeyFixture()
        var repository = fixture.repository(keychainAccount: "user-managed")
        repository.secretStorageMode = .userManagedPassphrase

        XCTAssertNil(try fixture.preparer.prepare(repository: repository))
        XCTAssertTrue(fixture.savedAccounts.isEmpty)
    }
}

private final class RecoveryKeyFixture: @unchecked Sendable {
    let storeID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var values: [String: String] = [:]
    var savedAccounts: [String] = []
    var deletedAccounts: [String] = []
    var savedValueOverride: String?
    var deleteShouldFail = false

    var canonicalAccount: String {
        "time-machine-password-\(storeID.uuidString)"
    }

    var preparer: TimeMachineRecoveryKeyRetentionPreparer {
        TimeMachineRecoveryKeyRetentionPreparer(
            loadOptional: { account in self.values[account] },
            save: { secret, account in
                self.savedAccounts.append(account)
                self.values[account] = self.savedValueOverride ?? secret
            },
            delete: { account in
                if self.deleteShouldFail {
                    throw KeychainSecretError.interactionNotAllowed
                }
                self.deletedAccounts.append(account)
                self.values.removeValue(forKey: account)
            }
        )
    }

    func repository(keychainAccount: String) -> BackupRepository {
        BackupRepository(
            name: "Time Machine",
            backend: .local(path: "/remote"),
            format: .timeMachine,
            timeMachineSettings: TimeMachineRepositorySettings(
                storeID: storeID,
                volumeName: "Delta Remote"
            ),
            secretStorageMode: .appManagedKeychain,
            keychainAccount: keychainAccount
        )
    }
}
