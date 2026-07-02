import DeltaCore
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let account = arguments.first, !account.isEmpty else {
    fputs("usage: DeltaSecretBridge <keychain-account>\n", stderr)
    exit(64)
}

do {
    let secret = try KeychainSecretStore().load(
        account: String(account),
        authenticationPolicy: .failIfInteractionNeeded
    )
    print(secret)
    exit(0)
} catch {
    fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
