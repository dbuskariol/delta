import Foundation

public enum RepositoryPasswordChangeResult: Equatable, Sendable {
    case completed
    case completedWithOldKeyRetained
}

public enum RepositoryPasswordError: Error, Equatable, LocalizedError {
    case destinationBusy
    case savedPasswordUnavailable(String)
    case savedPasswordRejected(String)
    case invalidKeyList
    case addKeyFailed(String)
    case newKeyIDMissing
    case keychainUpdateFailed(String)
    case newPasswordVerificationFailed(String)
    case rollbackFailed(String)
    case reconnectValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .destinationBusy:
            "This destination is currently in use. Wait for the active job to finish, then try again."
        case let .savedPasswordUnavailable(detail):
            "Delta could not read the currently saved password. Repair Password Access, then try again. \(detail)"
        case let .savedPasswordRejected(detail):
            "The currently saved password does not unlock this destination. Use Reconnect with Original Password first. \(detail)"
        case .invalidKeyList:
            "Delta could not identify the active encryption key, so no password changes were made."
        case let .addKeyFailed(detail):
            "Delta could not add the new encryption key. The existing password is unchanged. \(detail)"
        case .newKeyIDMissing:
            "The backup tool added a key but did not return its identifier. The existing password remains valid."
        case let .keychainUpdateFailed(detail):
            "The new key was not activated because Delta could not update Keychain. The existing password remains valid. \(detail)"
        case let .newPasswordVerificationFailed(detail):
            "The new password could not be verified. Delta restored the previous saved password and kept the existing key. \(detail)"
        case let .rollbackFailed(detail):
            "Delta could not complete or roll back the password change in Keychain. Both encryption keys were retained to prevent data loss. Use Reconnect with Original Password and keep the new password until access is verified. \(detail)"
        case let .reconnectValidationFailed(detail):
            "That password does not unlock this destination. No saved credentials were changed. \(detail)"
        }
    }
}

public struct RepositoryPasswordManager: Sendable {
    public var commandBuilder: ResticCommandBuilder
    public var runner: any ResticRunning
    public var lockManager: any RepositoryLocking
    public var loadSavedPassword: @Sendable (String) throws -> String
    public var savePassword: @Sendable (String, String) throws -> Void

    public init(
        commandBuilder: ResticCommandBuilder,
        runner: any ResticRunning = ResticRunner(),
        lockManager: any RepositoryLocking = RepositoryJobLockManager(),
        loadSavedPassword: @escaping @Sendable (String) throws -> String,
        savePassword: @escaping @Sendable (String, String) throws -> Void
    ) {
        self.commandBuilder = commandBuilder
        self.runner = runner
        self.lockManager = lockManager
        self.loadSavedPassword = loadSavedPassword
        self.savePassword = savePassword
    }

    public func reconnect(repository: BackupRepository, originalPassword: String) throws {
        guard let lock = try lockManager.acquire(repositoryID: repository.id) else {
            throw RepositoryPasswordError.destinationBusy
        }
        defer { withExtendedLifetime(lock) {} }

        let result = try runner.run(
            try commandBuilder.validateRepositoryPassword(repository: repository, password: originalPassword)
        )
        guard result.status == .succeeded || result.status == .warning else {
            throw RepositoryPasswordError.reconnectValidationFailed(result.userFacingMessage)
        }
        try savePassword(originalPassword, repository.keychainAccount)
    }

    public func rotate(repository: BackupRepository, newPassword: String) throws -> RepositoryPasswordChangeResult {
        guard let lock = try lockManager.acquire(repositoryID: repository.id) else {
            throw RepositoryPasswordError.destinationBusy
        }
        defer { withExtendedLifetime(lock) {} }

        let oldPassword: String
        do {
            oldPassword = try loadSavedPassword(repository.keychainAccount)
        } catch {
            throw RepositoryPasswordError.savedPasswordUnavailable(error.localizedDescription)
        }

        let keyListResult = try runner.run(try commandBuilder.repositoryKeys(repository: repository))
        guard keyListResult.status == .succeeded || keyListResult.status == .warning else {
            throw RepositoryPasswordError.savedPasswordRejected(keyListResult.userFacingMessage)
        }
        guard let oldKeyID = try Self.currentKeyID(from: keyListResult.standardOutput) else {
            throw RepositoryPasswordError.invalidKeyList
        }

        let addResult = try runner.run(
            try commandBuilder.addRepositoryKey(repository: repository, password: newPassword)
        )
        guard addResult.status == .succeeded || addResult.status == .warning else {
            throw RepositoryPasswordError.addKeyFailed(addResult.userFacingMessage)
        }
        guard let newKeyID = Self.addedKeyID(from: addResult.standardOutput) else {
            throw RepositoryPasswordError.newKeyIDMissing
        }

        do {
            try savePassword(newPassword, repository.keychainAccount)
        } catch {
            guard restoreOldPasswordAndRemoveNewKey(repository: repository, oldPassword: oldPassword, newKeyID: newKeyID) else {
                throw RepositoryPasswordError.rollbackFailed(error.localizedDescription)
            }
            throw RepositoryPasswordError.keychainUpdateFailed(error.localizedDescription)
        }

        let verifyResult = try runner.run(try commandBuilder.snapshots(repository: repository))
        guard verifyResult.status == .succeeded || verifyResult.status == .warning else {
            guard restoreOldPasswordAndRemoveNewKey(repository: repository, oldPassword: oldPassword, newKeyID: newKeyID) else {
                throw RepositoryPasswordError.rollbackFailed(verifyResult.userFacingMessage)
            }
            throw RepositoryPasswordError.newPasswordVerificationFailed(verifyResult.userFacingMessage)
        }

        let removeResult = try runner.run(
            try commandBuilder.removeRepositoryKey(repository: repository, keyID: oldKeyID)
        )
        guard removeResult.status == .succeeded || removeResult.status == .warning else {
            return .completedWithOldKeyRetained
        }
        return .completed
    }

    private func restoreOldPasswordAndRemoveNewKey(
        repository: BackupRepository,
        oldPassword: String,
        newKeyID: String
    ) -> Bool {
        do {
            try savePassword(oldPassword, repository.keychainAccount)
        } catch {
            return false
        }
        _ = try? runner.run(try commandBuilder.removeRepositoryKey(repository: repository, keyID: newKeyID))
        return true
    }

    static func currentKeyID(from output: String) throws -> String? {
        let keys = try JSONDecoder().decode([RepositoryKey].self, from: Data(output.utf8))
        return keys.first(where: \.current)?.id
    }

    static func addedKeyID(from output: String) -> String? {
        let pattern = #"\b[0-9a-fA-F]{64}\b"#
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(output[range]).lowercased()
    }

    private struct RepositoryKey: Decodable {
        var current: Bool
        var id: String
    }
}
