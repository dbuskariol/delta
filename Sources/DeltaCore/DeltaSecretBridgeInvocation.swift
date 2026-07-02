import Foundation

public struct DeltaSecretBridgeCommand: Equatable, Sendable {
    public var keychainAccount: String

    public init(keychainAccount: String) {
        self.keychainAccount = keychainAccount
    }
}

public enum DeltaSecretBridgeArgumentError: Error, Equatable, LocalizedError {
    case invalidArgumentCount(Int)
    case emptyAccount

    public var errorDescription: String? {
        switch self {
        case let .invalidArgumentCount(count):
            return "expected exactly one keychain account argument, received \(count)."
        case .emptyAccount:
            return "keychain account cannot be empty."
        }
    }
}

public enum DeltaSecretBridgeInvocation {
    public static func command(arguments: [String]) throws -> DeltaSecretBridgeCommand {
        guard arguments.count == 1 else {
            throw DeltaSecretBridgeArgumentError.invalidArgumentCount(arguments.count)
        }

        let account = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            throw DeltaSecretBridgeArgumentError.emptyAccount
        }

        return DeltaSecretBridgeCommand(keychainAccount: account)
    }
}
