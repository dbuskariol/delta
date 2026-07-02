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
        case "--export-diagnostics":
            runExportDiagnostics()
        case "--acceptance-seed-diagnostics":
            runAcceptanceSeedDiagnostics()
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

    private static func runExportDiagnostics() -> Never {
        do {
            let database = try DeltaDatabase.live()
            let report = DiagnosticReportBuilder().makeReport(
                snapshot: DiagnosticSnapshotCollector(database: database, bundle: .main).snapshot()
            )
            print(report, terminator: "")
            exit(0)
        } catch {
            fputs("Delta diagnostics error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceSeedDiagnostics() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_DIAGNOSTIC_ACCEPTANCE"] == "1" else {
            fputs("Delta diagnostic acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let database = try DeltaDatabase.live()
            let secret = "super-secret-diagnostic-value"
            let repositoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let profileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let jobID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            let repository = BackupRepository(
                id: repositoryID,
                name: "Diagnostics rest:https://user:\(secret)@example.com/repo",
                backend: .s3(endpoint: "https://s3.example.com", bucket: "delta-diagnostics", path: "acceptance", region: "us-east-1"),
                keychainAccount: "diagnostics-repository-secret",
                credentialReferences: [
                    RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: "diagnostics-aws-secret")
                ],
                createdAt: Date(timeIntervalSince1970: 10),
                lastVerifiedAt: Date(timeIntervalSince1970: 20)
            )
            let profile = BackupProfile(
                id: profileID,
                name: "Diagnostics AWS_SECRET_ACCESS_KEY=\(secret)",
                sourceMode: .customFolders,
                sources: [
                    BackupSource(path: "/tmp/delta-diagnostics")
                ],
                repositoryID: repositoryID,
                schedule: BackupSchedule(kind: .hourly(minute: 0), isEnabled: true),
                createdAt: Date(timeIntervalSince1970: 30),
                updatedAt: Date(timeIntervalSince1970: 30)
            )
            let job = JobRun(
                id: jobID,
                profileID: profileID,
                repositoryID: repositoryID,
                kind: .backup,
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 40),
                finishedAt: Date(timeIntervalSince1970: 50),
                exitCode: 1,
                message: "Backup failed for rest:https://user:\(secret)@example.com/repo with AWS_SECRET_ACCESS_KEY=\(secret)"
            )
            let snapshot = ResticSnapshot(
                id: "diagnostic-snapshot",
                time: Date(timeIntervalSince1970: 60),
                paths: ["/tmp/delta-diagnostics"],
                tags: ["delta", "profile:\(profileID.uuidString)"]
            )
            try database.saveRepository(repository)
            try database.saveProfile(profile)
            try database.saveJobRun(job)
            try database.saveSnapshot(snapshot, repositoryID: repositoryID)
            print("Seeded diagnostic acceptance state.")
            exit(0)
        } catch {
            fputs("Delta diagnostic acceptance error: \(error.localizedDescription)\n", stderr)
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
