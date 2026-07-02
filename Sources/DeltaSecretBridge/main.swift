import DeltaCore
import Foundation

let command: DeltaSecretBridgeCommand
do {
    command = try DeltaSecretBridgeInvocation.command(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as DeltaSecretBridgeArgumentError {
    fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
    fputs("usage: DeltaSecretBridge <keychain-account>\n", stderr)
    exit(64)
} catch {
    fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

do {
    let secret = try KeychainSecretStore().load(
        account: command.keychainAccount,
        authenticationPolicy: .failIfInteractionNeeded
    )
    print(secret)
    exit(0)
} catch {
    fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
