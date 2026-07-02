import DeltaCore
import Foundation
import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model = DeltaAppModel()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()
    @StateObject private var statusItemController = DeltaStatusItemController()
    @AppStorage(
        DeltaAppPreferenceKeys.showsMenuBarExtra,
        store: DeltaAppPreferences.sharedStore()
    ) private var showsMenuBarExtra = true

    init() {
        Self.runCommandLineModeIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 1120, minHeight: 720)
                .background(
                    DeltaStatusItemInstaller(
                        controller: statusItemController,
                        model: model,
                        softwareUpdateController: softwareUpdateController,
                        isVisible: showsMenuBarExtra
                    )
                )
        }
        .windowStyle(.hiddenTitleBar)
    }

    private static func runCommandLineModeIfNeeded() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "--secret-bridge":
            runSecretBridge(arguments: Array(arguments.dropFirst()))
        case "--run-due-backups":
            runDueBackups()
        case "--acceptance-save-secret":
            runAcceptanceSave(arguments: Array(arguments.dropFirst()))
        case "--acceptance-delete-secret":
            runAcceptanceDelete(arguments: Array(arguments.dropFirst()))
        default:
            return
        }
    }

    private static func runSecretBridge(arguments: [String]) -> Never {
        do {
            let command = try DeltaSecretBridgeInvocation.command(arguments: arguments)
            let secret = try KeychainSecretStore().load(
                account: command.keychainAccount,
                authenticationPolicy: .failIfInteractionNeeded
            )
            print(secret)
            exit(0)
        } catch let error as DeltaSecretBridgeArgumentError {
            fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
            fputs("usage: Delta --secret-bridge <keychain-account>\n", stderr)
            exit(64)
        } catch {
            fputs("DeltaSecretBridge error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runDueBackups() -> Never {
        do {
            let status = try DeltaAgentRunner.runDueBackups(
                secretBridgeURL: selfExecutableURL(),
                secretBridgeArguments: ["--secret-bridge"]
            )
            exit(status)
        } catch {
            fputs("DeltaAgent error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceSave(arguments: [String]) -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_KEYCHAIN_ACCEPTANCE"] == "1" else {
            fputs("Delta acceptance command is disabled.\n", stderr)
            exit(64)
        }
        guard arguments.count == 1, let account = arguments.first, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("usage: Delta --acceptance-save-secret <keychain-account>\n", stderr)
            exit(64)
        }
        guard let secret = ProcessInfo.processInfo.environment["DELTA_KEYCHAIN_ACCEPTANCE_SECRET"], !secret.isEmpty else {
            fputs("DELTA_KEYCHAIN_ACCEPTANCE_SECRET is required.\n", stderr)
            exit(64)
        }

        do {
            try KeychainSecretStore().save(
                secret: secret,
                account: account,
                authenticationPolicy: .failIfInteractionNeeded
            )
            print("Saved throwaway destination secret.")
            exit(0)
        } catch {
            fputs("Delta acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceDelete(arguments: [String]) -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_KEYCHAIN_ACCEPTANCE"] == "1" else {
            fputs("Delta acceptance command is disabled.\n", stderr)
            exit(64)
        }
        guard arguments.count == 1, let account = arguments.first, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("usage: Delta --acceptance-delete-secret <keychain-account>\n", stderr)
            exit(64)
        }

        do {
            try KeychainSecretStore().delete(account: account)
            print("Deleted throwaway destination secret.")
            exit(0)
        } catch {
            fputs("Delta acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func selfExecutableURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/bin/false")
    }
}
