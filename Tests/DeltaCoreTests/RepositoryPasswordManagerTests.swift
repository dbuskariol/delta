import Foundation
import XCTest
@testable import DeltaCore

final class RepositoryPasswordManagerTests: XCTestCase {
    private let oldKeyID = String(repeating: "a", count: 64)
    private let newKeyID = String(repeating: "b", count: 64)

    func testRotationAddsVerifiesAndStoresNewKeyBeforeRemovingOldKey() throws {
        let runner = PasswordMockRunner(results: successfulRotationResults())
        let store = PasswordStoreBox(value: "old-password")
        let manager = makeManager(runner: runner, store: store)

        let result = try manager.rotate(repository: repository(), newPassword: "new-password-value")

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(store.value, "new-password-value")
        XCTAssertEqual(runner.subcommands, ["key list", "key add", "snapshots", "key remove"])
        XCTAssertTrue(runner.commands[1].arguments.contains("/dev/stdin"))
        XCTAssertEqual(runner.commands[3].arguments.last, oldKeyID)
    }

    func testRotationRejectsWrongSavedPasswordWithoutChangingKeychain() throws {
        let failure = ResticRunResult(exitCode: 12, standardOutput: "", standardError: "wrong password")
        let runner = PasswordMockRunner(results: [failure])
        let store = PasswordStoreBox(value: "wrong-password")
        let manager = makeManager(runner: runner, store: store)

        XCTAssertThrowsError(try manager.rotate(repository: repository(), newPassword: "new-password-value")) { error in
            guard case RepositoryPasswordError.savedPasswordRejected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.value, "wrong-password")
        XCTAssertEqual(store.savedValues, [])
        XCTAssertEqual(runner.subcommands, ["key list"])
    }

    func testRotationRollsBackAddedKeyWhenKeychainUpdateFails() throws {
        let runner = PasswordMockRunner(results: [keyListResult(), addKeyResult(), successResult()])
        let store = PasswordStoreBox(value: "old-password", failOnValue: "new-password-value")
        let manager = makeManager(runner: runner, store: store)

        XCTAssertThrowsError(try manager.rotate(repository: repository(), newPassword: "new-password-value")) { error in
            guard case RepositoryPasswordError.keychainUpdateFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.value, "old-password")
        XCTAssertEqual(runner.subcommands, ["key list", "key add", "key remove"])
        XCTAssertEqual(runner.commands.last?.arguments.last, newKeyID)
    }

    func testRotationRestoresOldPasswordWhenNewKeyVerificationFails() throws {
        let verifyFailure = ResticRunResult(exitCode: 12, standardOutput: "", standardError: "wrong password")
        let runner = PasswordMockRunner(results: [keyListResult(), addKeyResult(), verifyFailure, successResult()])
        let store = PasswordStoreBox(value: "old-password")
        let manager = makeManager(runner: runner, store: store)

        XCTAssertThrowsError(try manager.rotate(repository: repository(), newPassword: "new-password-value")) { error in
            guard case RepositoryPasswordError.newPasswordVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.value, "old-password")
        XCTAssertEqual(store.savedValues, ["new-password-value", "old-password"])
        XCTAssertEqual(runner.commands.last?.arguments.last, newKeyID)
    }

    func testRotationKeepsVerifiedNewPasswordWhenOldKeyRemovalFails() throws {
        let removeFailure = ResticRunResult(exitCode: 11, standardOutput: "", standardError: "repository is locked")
        let runner = PasswordMockRunner(results: [keyListResult(), addKeyResult(), successResult(), removeFailure])
        let store = PasswordStoreBox(value: "old-password")
        let manager = makeManager(runner: runner, store: store)

        let result = try manager.rotate(repository: repository(), newPassword: "new-password-value")

        XCTAssertEqual(result, RepositoryPasswordChangeResult.completedWithOldKeyRetained)
        XCTAssertEqual(store.value, "new-password-value")
    }

    func testRotationRetainsBothKeysWhenKeychainRollbackAlsoFails() throws {
        let runner = PasswordMockRunner(results: [keyListResult(), addKeyResult()])
        let store = PasswordStoreBox(value: "old-password", failsAllSaves: true)
        let manager = makeManager(runner: runner, store: store)

        XCTAssertThrowsError(try manager.rotate(repository: repository(), newPassword: "new-password-value")) { error in
            guard case RepositoryPasswordError.rollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(store.value, "old-password")
        XCTAssertEqual(runner.subcommands, ["key list", "key add"])
    }

    func testReconnectValidatesBeforeReplacingSavedPassword() throws {
        let runner = PasswordMockRunner(results: [successResult()])
        let store = PasswordStoreBox(value: "incorrect-saved-password")
        let manager = makeManager(runner: runner, store: store)

        try manager.reconnect(repository: repository(), originalPassword: "original-password")

        XCTAssertEqual(store.value, "original-password")
        XCTAssertEqual(runner.subcommands, ["snapshots"])
        XCTAssertTrue(runner.commands[0].arguments.contains("--password-file"))
        XCTAssertFalse(runner.commands[0].arguments.contains("--password-command"))
    }

    func testReconnectNeverSavesAnInvalidPassword() throws {
        let failure = ResticRunResult(exitCode: 12, standardOutput: "", standardError: "wrong password")
        let runner = PasswordMockRunner(results: [failure])
        let store = PasswordStoreBox(value: "saved-password")
        let manager = makeManager(runner: runner, store: store)

        XCTAssertThrowsError(try manager.reconnect(repository: repository(), originalPassword: "wrong-password"))
        XCTAssertEqual(store.value, "saved-password")
        XCTAssertEqual(store.savedValues, [])
    }

    private func makeManager(runner: PasswordMockRunner, store: PasswordStoreBox) -> RepositoryPasswordManager {
        RepositoryPasswordManager(
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
                secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/Delta"),
                secretBridgeArguments: ["--secret-bridge"]
            ),
            runner: runner,
            lockManager: AlwaysAvailablePasswordLock(),
            loadSavedPassword: { _ in store.value },
            savePassword: { value, _ in try store.save(value) }
        )
    }

    private func repository() -> BackupRepository {
        BackupRepository(name: "Destination", backend: .local(path: "/tmp/repository"), keychainAccount: "account")
    }

    private func successfulRotationResults() -> [ResticRunResult] {
        [keyListResult(), addKeyResult(), successResult(), successResult()]
    }

    private func successResult() -> ResticRunResult {
        ResticRunResult(exitCode: 0, standardOutput: "[]", standardError: "")
    }

    private func keyListResult() -> ResticRunResult {
        ResticRunResult(
            exitCode: 0,
            standardOutput: "[{\"current\":true,\"id\":\"\(oldKeyID)\"}]",
            standardError: ""
        )
    }

    private func addKeyResult() -> ResticRunResult {
        ResticRunResult(
            exitCode: 0,
            standardOutput: "saved new key with ID \(newKeyID)\n",
            standardError: ""
        )
    }
}

private final class PasswordMockRunner: ResticRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ResticRunResult]
    private(set) var commands: [ResticCommand] = []

    init(results: [ResticRunResult]) {
        self.results = results
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        return results.removeFirst()
    }

    var subcommands: [String] {
        commands.map { command in
            if command.arguments.contains("key") {
                let index = command.arguments.firstIndex(of: "key")!
                return "key \(command.arguments[index + 1])"
            }
            return command.arguments.contains("snapshots") ? "snapshots" : "unknown"
        }
    }
}

private final class PasswordStoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String
    private let failOnValue: String?
    private let failsAllSaves: Bool
    private(set) var savedValues: [String] = []

    init(value: String, failOnValue: String? = nil, failsAllSaves: Bool = false) {
        storedValue = value
        self.failOnValue = failOnValue
        self.failsAllSaves = failsAllSaves
    }

    var value: String {
        lock.withLock { storedValue }
    }

    func save(_ value: String) throws {
        try lock.withLock {
            if failsAllSaves || value == failOnValue {
                throw PasswordStoreTestError.saveFailed
            }
            storedValue = value
            savedValues.append(value)
        }
    }
}

private enum PasswordStoreTestError: Error {
    case saveFailed
}

private struct AlwaysAvailablePasswordLock: RepositoryLocking {
    func acquire(repositoryID: UUID) throws -> RepositoryJobLock? {
        try RepositoryJobLockManager(
            lockDirectoryProvider: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("delta-password-tests", isDirectory: true)
            }
        ).acquire(repositoryID: repositoryID)
    }
}
