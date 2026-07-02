import Foundation
import LocalAuthentication
import Security

public enum KeychainSecretError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case interactionNotAllowed
    case invalidData

    public var errorDescription: String? {
        switch self {
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
    public static let defaultService = "com.delta.backup.secrets"

    public var service: String
    public var trustedApplicationPaths: [String]

    public init(service: String = Self.defaultService, trustedApplicationPaths: [String]? = nil) {
        self.service = service
        self.trustedApplicationPaths = trustedApplicationPaths ?? Self.defaultTrustedApplicationPaths()
    }

    public func save(
        secret: String,
        account: String,
        authenticationPolicy: KeychainAuthenticationPolicy = .allowUserInteraction
    ) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)
        apply(authenticationPolicy, to: &query)
        let trustedAccess = try trustedApplicationAccess()

        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let trustedAccess {
            attributes[kSecAttrAccess as String] = trustedAccess
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(for: updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let trustedAccess {
            addQuery[kSecAttrAccess as String] = trustedAccess
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(for: addStatus)
        }
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

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretError.unexpectedStatus(status)
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

        let trustedApplications = try paths.map { path in
            var application: SecTrustedApplication?
            let status = path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
            guard status == errSecSuccess, let application else {
                throw KeychainSecretError.unexpectedStatus(status)
            }
            return application
        }

        var access: SecAccess?
        let status = SecAccessCreate("Delta repository secrets" as CFString, trustedApplications as CFArray, &access)
        guard status == errSecSuccess else {
            throw KeychainSecretError.unexpectedStatus(status)
        }
        return access
    }

    private func apply(_ authenticationPolicy: KeychainAuthenticationPolicy, to query: inout [String: Any]) {
        switch authenticationPolicy {
        case .allowUserInteraction:
            break
        case .failIfInteractionNeeded:
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
    }

    private func keychainError(for status: OSStatus) -> KeychainSecretError {
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
