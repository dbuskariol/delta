import Foundation
import Security

public enum KeychainSecretError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status): "Keychain operation failed with status \(status)."
        case .invalidData: "The Keychain item did not contain UTF-8 text."
        }
    }
}

public struct KeychainSecretStore: Sendable {
    public static let defaultService = "com.delta.backup.repository-secrets"

    public var service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func save(secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecretError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretError.unexpectedStatus(addStatus)
        }
    }

    public func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainSecretError.unexpectedStatus(status)
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

    public func generateAndSave(account: String, byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw KeychainSecretError.unexpectedStatus(status)
        }
        let secret = Data(bytes).base64EncodedString()
        try save(secret: secret, account: account)
        return secret
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
