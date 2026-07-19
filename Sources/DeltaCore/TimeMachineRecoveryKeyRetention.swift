import Foundation

public enum TimeMachineRecoveryKeyRetentionError: Error, Equatable, LocalizedError {
    case missingSavedKey
    case conflictingSavedKey
    case copyVerificationFailed
    case copyRollbackFailed

    public var errorDescription: String? {
        switch self {
        case .missingSavedKey:
            "Delta could not find this disk's saved recovery key. Removal stopped before changing local configuration or cache data. Keep the original password or an exported recovery key before removing this destination."
        case .conflictingSavedKey:
            "Delta found a different saved recovery key for this remote Time Machine disk. Removal stopped before changing local configuration or cache data. Keep an exported recovery key and resolve the Keychain conflict before trying again."
        case .copyVerificationFailed:
            "Delta could not verify the retained recovery key. Removal stopped before changing local configuration or cache data. Try again after unlocking the login keychain."
        case .copyRollbackFailed:
            "Delta could not verify or remove a partially copied recovery key. Removal stopped before changing local configuration or cache data. Resolve the saved-key issue in Keychain Access before trying again."
        }
    }
}

public struct TimeMachineRecoveryKeyRetention: Equatable, Sendable {
    public var retainedAccount: String
    public var obsoleteAccount: String?

    public init(retainedAccount: String, obsoleteAccount: String?) {
        self.retainedAccount = retainedAccount
        self.obsoleteAccount = obsoleteAccount
    }
}

/// Makes an app-managed Time Machine disk password recoverable from the
/// immutable remote store identity before Delta deletes local configuration.
///
/// Early development builds could save the password under a repository-scoped
/// account. That account cannot be rediscovered after its repository row is
/// removed. The canonical account is derived from the authenticated store ID,
/// so the Existing Disk workflow can locate it without persisting a second
/// local index. Existing canonical data is never overwritten unless it already
/// matches the active disk password.
public struct TimeMachineRecoveryKeyRetentionPreparer: Sendable {
    public var loadOptional: @Sendable (String) throws -> String?
    public var save: @Sendable (String, String) throws -> Void
    public var delete: @Sendable (String) throws -> Void

    public init(secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.loadOptional = { account in
            do {
                return try secretStore.load(
                    account: account,
                    authenticationPolicy: .allowUserInteraction
                )
            } catch KeychainSecretError.itemNotFound {
                return nil
            }
        }
        self.save = { secret, account in
            try secretStore.save(
                secret: secret,
                account: account,
                authenticationPolicy: .allowUserInteraction
            )
        }
        self.delete = { account in
            try secretStore.delete(
                account: account,
                authenticationPolicy: .allowUserInteraction
            )
        }
    }

    public init(
        loadOptional: @escaping @Sendable (String) throws -> String?,
        save: @escaping @Sendable (String, String) throws -> Void,
        delete: @escaping @Sendable (String) throws -> Void
    ) {
        self.loadOptional = loadOptional
        self.save = save
        self.delete = delete
    }

    public func prepare(
        repository: BackupRepository
    ) throws -> TimeMachineRecoveryKeyRetention? {
        guard
            repository.format == .timeMachine,
            repository.secretStorageMode == .appManagedKeychain,
            let settings = repository.timeMachineSettings
        else {
            return nil
        }

        let retainedAccount = settings.diskPasswordKeychainAccount
        guard let activeSecret = try loadOptional(repository.keychainAccount) else {
            throw TimeMachineRecoveryKeyRetentionError.missingSavedKey
        }

        if repository.keychainAccount == retainedAccount {
            return TimeMachineRecoveryKeyRetention(
                retainedAccount: retainedAccount,
                obsoleteAccount: nil
            )
        }

        if let retainedSecret = try loadOptional(retainedAccount) {
            guard secretsMatch(activeSecret, retainedSecret) else {
                throw TimeMachineRecoveryKeyRetentionError.conflictingSavedKey
            }
        } else {
            try save(activeSecret, retainedAccount)
            do {
                guard
                    let copiedSecret = try loadOptional(retainedAccount),
                    secretsMatch(activeSecret, copiedSecret)
                else {
                    throw TimeMachineRecoveryKeyRetentionError.copyVerificationFailed
                }
            } catch {
                do {
                    try delete(retainedAccount)
                } catch {
                    throw TimeMachineRecoveryKeyRetentionError.copyRollbackFailed
                }
                throw error
            }
        }

        return TimeMachineRecoveryKeyRetention(
            retainedAccount: retainedAccount,
            obsoleteAccount: repository.keychainAccount
        )
    }

    private func secretsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsData = Data(lhs.utf8)
        let rhsData = Data(rhs.utf8)
        let count = max(lhsData.count, rhsData.count)
        var difference: UInt8 = lhsData.count == rhsData.count ? 0 : 1
        for index in 0..<count {
            let lhsByte = index < lhsData.count ? lhsData[index] : 0
            let rhsByte = index < rhsData.count ? rhsData[index] : 0
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
