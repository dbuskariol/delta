import Foundation
import DeltaSecurity
import LocalAuthentication
import Security

public enum KeychainSecretError: Error, Equatable, LocalizedError {
    case itemNotFound
    case keychainUnavailable(OSStatus)
    case unexpectedStatus(OSStatus)
    case interactionNotAllowed
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "The saved destination secret is missing. Re-save the destination or repair password access in Settings."
        case let .keychainUnavailable(status):
            "macOS could not open the login keychain for Delta (status \(status)). Unlock or reset the login keychain in Keychain Access, then try again."
        case let .unexpectedStatus(status):
            "Keychain operation failed with status \(status)."
        case .interactionNotAllowed:
            "Delta could not read this saved destination secret without user interaction. Use Repair Password Access in Settings or re-save the destination."
        case .invalidData: "The Keychain item did not contain UTF-8 text."
        }
    }
}

public enum KeychainAuthenticationPolicy: Sendable {
    case allowUserInteraction
    case failIfInteractionNeeded
}

public struct KeychainSecretStore: Sendable {
    public static let defaultService = "com.delta.backup.destination-secrets"
    static let accessPromptName = "Delta destination secrets"

    public var service: String
    public var trustedApplicationPaths: [String]

    public init(
        service: String = Self.defaultService,
        trustedApplicationPaths: [String]? = nil
    ) {
        self.service = service
        self.trustedApplicationPaths = trustedApplicationPaths ?? Self.defaultTrustedApplicationPaths()
    }

    public func save(
        secret: String,
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy = .allowUserInteraction
    ) throws {
        let data = Data(secret.utf8)
        let query = updateQuery(account: account, authenticationPolicy: authenticationPolicy)
        // Updating an existing item's ACL can trigger an authorization prompt for each
        // trusted executable. Password changes only need an atomic value replacement;
        // ACL changes are handled by the explicit password-access repair workflow.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            existingItemValueUpdateAttributes(data: data) as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(for: updateStatus)
        }

        let addQuery = addQuery(
            account: account,
            data: data,
            trustedAccess: try trustedApplicationAccess(),
            authenticationPolicy: authenticationPolicy
        )
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(for: addStatus)
        }
    }

    func existingItemValueUpdateAttributes(data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }

    public func load(
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy = .allowUserInteraction
    ) throws -> String {
        let query = loadQuery(account: account, authenticationPolicy: authenticationPolicy)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw keychainError(for: status)
        }
        guard
            let data = result as? Data,
            let secret = String(data: data, encoding: .utf8)
        else {
            throw KeychainSecretError.invalidData
        }
        return secret
    }

    public func delete(
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy = .failIfInteractionNeeded
    ) throws {
        let status = SecItemDelete(updateQuery(account: account, authenticationPolicy: authenticationPolicy) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(for: status)
        }
    }

    public func generateAndSave(
        account: String,
        byteCount: Int = 32,
        authenticationPolicy: KeychainAuthenticationPolicy = .allowUserInteraction
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw keychainError(for: status)
        }
        let secret = Data(bytes).base64EncodedString()
        try save(secret: secret, account: account, authenticationPolicy: authenticationPolicy)
        return secret
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func updateQuery(account: String, authenticationPolicy: KeychainAuthenticationPolicy) -> [String: Any] {
        var query = baseQuery(account: account)
        apply(authenticationPolicy, to: &query)
        return query
    }

    func addQuery(
        account: String,
        data: Data,
        trustedAccess: SecAccess?,
        authenticationPolicy: KeychainAuthenticationPolicy
    ) -> [String: Any] {
        var query = updateQuery(account: account, authenticationPolicy: authenticationPolicy)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let trustedAccess {
            query[kSecAttrAccess as String] = trustedAccess
        }
        return query
    }

    func loadQuery(account: String, authenticationPolicy: KeychainAuthenticationPolicy) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        apply(authenticationPolicy, to: &query)
        return query
    }

    private func trustedApplicationAccess() throws -> SecAccess? {
        let paths = trustedApplicationPaths.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard !paths.isEmpty else {
            return nil
        }

        let duplicatedPaths = try paths.map { path in
            guard let duplicatedPath = strdup(path) else {
                throw KeychainSecretError.unexpectedStatus(errSecAllocate)
            }
            return duplicatedPath
        }
        defer {
            for path in duplicatedPaths {
                free(path)
            }
        }

        let pathPointers = UnsafeMutablePointer<UnsafePointer<CChar>>.allocate(capacity: duplicatedPaths.count)
        defer {
            pathPointers.deallocate()
        }
        for index in duplicatedPaths.indices {
            pathPointers[index] = UnsafePointer(duplicatedPaths[index])
        }

        var unmanagedAccess: Unmanaged<SecAccess>?
        let status = DeltaCreateTrustedApplicationAccess(
            pathPointers,
            duplicatedPaths.count,
            Self.accessPromptName as CFString,
            &unmanagedAccess
        )
        guard status == errSecSuccess else {
            throw KeychainSecretError.unexpectedStatus(status)
        }
        return unmanagedAccess?.takeRetainedValue()
    }

    private func apply(_ authenticationPolicy: KeychainAuthenticationPolicy, to query: inout [String: Any]) {
        switch authenticationPolicy {
        case .allowUserInteraction:
            break
        case .failIfInteractionNeeded:
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
    }

    private func keychainError(for status: OSStatus) -> KeychainSecretError {
        if status == errSecItemNotFound {
            return .itemNotFound
        }
        if status == errSecNoSuchKeychain || status == errSecInvalidKeychain || status == errSecNoDefaultKeychain || status == errSecNotAvailable {
            return .keychainUnavailable(status)
        }
        if status == errSecInteractionNotAllowed {
            return .interactionNotAllowed
        }
        return .unexpectedStatus(status)
    }

    private static func defaultTrustedApplicationPaths() -> [String] {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let directory = executable.deletingLastPathComponent()
        return ["Delta", "DeltaAgent", "DeltaSecretBridge"]
            .map { directory.appendingPathComponent($0).path }
    }

}
