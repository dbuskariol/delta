import DeltaCore
import Foundation
import SwiftUI

@main
struct DeltaApp: App {
    @StateObject private var model: DeltaAppModel
    @StateObject private var softwareUpdateController: SoftwareUpdateController
    @StateObject private var statusItemController = DeltaStatusItemController()
    @AppStorage(
        DeltaAppPreferenceKeys.showsMenuBarExtra,
        store: DeltaAppPreferences.sharedStore()
    ) private var showsMenuBarExtra = true

    init() {
        Self.runCommandLineModeIfNeeded()
        let model = DeltaAppModel()
        let softwareUpdateController = SoftwareUpdateController(
            readinessProvider: { [weak model] in
                model?.softwareUpdateReadiness ?? .applicationStateUnavailable
            },
            blockedHandler: { [weak model] readiness, message in
                guard let model else { return }
                model.alertMessage = message
                switch readiness {
                case .timeMachineDestinationsConnected:
                    model.selectedSection = .destinations
                case .operationInProgress:
                    model.selectedSection = .activity
                case .applicationStateUnavailable, .ready:
                    model.selectedSection = .settings
                }
            }
        )
        _model = StateObject(wrappedValue: model)
        _softwareUpdateController = StateObject(wrappedValue: softwareUpdateController)
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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.selectedSection = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Navigate") {
                navigationCommand("Dashboard", section: .dashboard, key: "1")
                navigationCommand("Backups", section: .backups, key: "2")
                navigationCommand("Destinations", section: .destinations, key: "3")
                navigationCommand("Restore", section: .restore, key: "4")
                navigationCommand("Activity", section: .activity, key: "5")
            }
        }
    }

    private func navigationCommand(
        _ title: String,
        section: DeltaAppModel.Section,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            model.selectedSection = section
        }
        .keyboardShortcut(key, modifiers: .command)
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
        case "--acceptance-local-lifecycle":
            runAcceptanceLocalLifecycle()
        case "--acceptance-run-control":
            runAcceptanceRunControl()
        case "--acceptance-external-lifecycle":
            runAcceptanceExternalLifecycle()
        case "--acceptance-external-preflight":
            runAcceptanceExternalPreflight()
        case "--acceptance-preferences":
            runAcceptancePreferences()
        case "--acceptance-menu-bar-surface":
            runAcceptanceMenuBarSurface()
        case "--acceptance-scheduled-service":
            runAcceptanceScheduledService(arguments: Array(arguments.dropFirst()))
        case "--acceptance-time-machine-system-support":
            runAcceptanceTimeMachineSystemSupport(
                arguments: Array(arguments.dropFirst())
            )
        case "--acceptance-seed-scheduled-agent":
            runAcceptanceSeedScheduledAgent(arguments: Array(arguments.dropFirst()))
        case "--acceptance-verify-scheduled-agent":
            runAcceptanceVerifyScheduledAgent(arguments: Array(arguments.dropFirst()))
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

    private static func runAcceptanceScheduledService(arguments: [String]) -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_SERVICE_MANAGEMENT_ACCEPTANCE"] == "1" else {
            fputs("Delta Service Management acceptance command is disabled.\n", stderr)
            exit(64)
        }
        guard arguments.count == 1, let action = arguments.first else {
            fputs("usage: Delta --acceptance-scheduled-service <status|register|unregister>\n", stderr)
            exit(64)
        }

        do {
            switch action {
            case "status":
                break
            case "register":
                try LaunchAgentController.register()
            case "unregister":
                try LaunchAgentController.unregister()
            default:
                fputs("usage: Delta --acceptance-scheduled-service <status|register|unregister>\n", stderr)
                exit(64)
            }
        } catch {
            fputs("Delta Service Management acceptance failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        let executableURL = LaunchAgentBundleLayout.agentExecutableURL(in: .main)
        let plistURL = LaunchAgentBundleLayout.plistURL(
            in: .main,
            plistName: LaunchAgentController.defaultPlistName
        )
        let plistProgram: String?
        do {
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            plistProgram = (plist as? [String: Any])?["BundleProgram"] as? String
        } catch {
            plistProgram = nil
        }
        let status = LaunchAgentController.status()

        print("Scheduled service status: \(status.stableValue)")
        print("Scheduled service program: \(plistProgram ?? "missing")")
        print("Scheduled service executable: \(FileManager.default.isExecutableFile(atPath: executableURL.path) ? "present" : "missing")")

        guard action == "status" else {
            exit(0)
        }
        guard
            plistProgram == LaunchAgentBundleLayout.agentExecutableRelativePath,
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            status != .notFound,
            status != .unavailable
        else {
            exit(1)
        }
        if case .unknown = status {
            exit(1)
        }
        exit(0)
    }

    private static func runAcceptanceTimeMachineSystemSupport(
        arguments: [String]
    ) -> Never {
        guard ProcessInfo.processInfo.environment[
            "DELTA_ENABLE_TIME_MACHINE_SYSTEM_ACCEPTANCE"
        ] == "1" else {
            fputs(
                "Delta Time Machine system-support acceptance command is disabled.\n",
                stderr
            )
            exit(64)
        }
        guard arguments.count == 1, let action = arguments.first else {
            fputs(
                "usage: Delta --acceptance-time-machine-system-support <status|register|verify|unregister>\n",
                stderr
            )
            exit(64)
        }

        let bundle = Bundle.main
        let isCanonical = TimeMachineInstalledApplicationPolicy
            .isCanonicalInstallation(bundleURL: bundle.bundleURL)
        var readiness = "not checked"

        do {
            switch action {
            case "status":
                break
            case "register":
                guard isCanonical else {
                    throw TimeMachineSetupHelperReadinessError
                        .noncanonicalInstallation
                }
                var failures: [String] = []
                do {
                    try TimeMachineServiceController.register()
                } catch {
                    if !TimeMachineSystemAccessRegistrationPolicy.accepted(
                        status: TimeMachineServiceController.status()
                    ) {
                        failures.append(
                            "storage service: \(error.localizedDescription)"
                        )
                    }
                }
                do {
                    try TimeMachineSetupHelperController.register()
                } catch {
                    if !TimeMachineSystemAccessRegistrationPolicy.accepted(
                        status: TimeMachineSetupHelperController.status()
                    ) {
                        failures.append(
                            "setup helper: \(error.localizedDescription)"
                        )
                    }
                }
                if !failures.isEmpty {
                    throw NSError(
                        domain: "com.delta.backup.acceptance.time-machine",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: failures.joined(
                                separator: "; "
                            )
                        ]
                    )
                }
            case "verify":
                guard TimeMachineServiceController.status() == .enabled else {
                    throw TimeMachineSystemAccessRepairError
                        .registrationIncomplete
                }
                guard TimeMachineSetupHelperController.status() == .enabled else {
                    throw TimeMachineSystemAccessRepairError
                        .registrationIncomplete
                }
                try TimeMachineSetupHelperRuntimeVerifier.verify(bundle: bundle)
                readiness = "verified"
            case "unregister":
                guard isCanonical else {
                    throw TimeMachineSetupHelperReadinessError
                        .noncanonicalInstallation
                }
                if TimeMachineSetupHelperController.status()
                    != .notRegistered
                {
                    try TimeMachineSetupHelperController.unregister()
                }
                if TimeMachineServiceController.status() != .notRegistered {
                    try TimeMachineServiceController.unregister()
                }
            default:
                fputs(
                    "usage: Delta --acceptance-time-machine-system-support <status|register|verify|unregister>\n",
                    stderr
                )
                exit(64)
            }
        } catch {
            fputs(
                "Delta Time Machine system-support acceptance failed: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }

        let helperURL = bundle.bundleURL.appendingPathComponent(
            TimeMachineSetupHelperController.executableRelativePath
        )
        let helperCodeHash = (try? TimeMachineSetupHelperController
            .installedCodeHash(bundle: bundle))?.map {
                String(format: "%02x", $0)
            }.joined()

        print(
            "Time Machine app installation: \(isCanonical ? "canonical" : "noncanonical")"
        )
        print(
            "Time Machine storage service status: \(TimeMachineServiceController.status().stableValue)"
        )
        print(
            "Time Machine setup helper status: \(TimeMachineSetupHelperController.status().stableValue)"
        )
        print(
            "Time Machine setup helper executable: \(FileManager.default.isExecutableFile(atPath: helperURL.path) ? "present" : "missing")"
        )
        print(
            "Time Machine setup helper code hash: \(helperCodeHash ?? "unavailable")"
        )
        print("Time Machine setup helper readiness: \(readiness)")
        exit(0)
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
            let destinationSecretAccount = "diagnostics-repository-secret"
            let backendSecretAccount = "diagnostics-aws-secret"
            let repository = BackupRepository(
                id: repositoryID,
                name: "Diagnostics rest:https://user:\(secret)@example.com/repo",
                backend: .s3(endpoint: "https://s3.example.com", bucket: "delta-diagnostics", path: "acceptance", region: "us-east-1"),
                keychainAccount: destinationSecretAccount,
                credentialReferences: [
                    RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: backendSecretAccount)
                ],
                createdAt: Date(timeIntervalSince1970: 10),
                lastVerifiedAt: Date(timeIntervalSince1970: 20)
            )
            let profile = BackupProfile(
                id: profileID,
                name: "Diagnostics AWS_SECRET_ACCESS_KEY=\(secret)",
                sourceMode: .customFolders,
                sources: [
                    BackupSource(path: "/Users/private-user/Documents")
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
                message: "Backup failed for rest:https://user:\(secret)@example.com/repo with AWS_SECRET_ACCESS_KEY=\(secret); could not read /Users/private-user/Documents/file.txt"
            )
            let snapshot = ResticSnapshot(
                id: "diagnostic-snapshot",
                time: Date(timeIntervalSince1970: 60),
                paths: ["/Users/private-user/Documents"],
                tags: ["delta", "profile:\(profileID.uuidString)"]
            )
            let secretStore = KeychainSecretStore()
            try? secretStore.delete(account: destinationSecretAccount)
            try? secretStore.delete(account: backendSecretAccount)
            try secretStore.save(
                secret: "diagnostic-destination-password",
                account: destinationSecretAccount,
                authenticationPolicy: .failIfInteractionNeeded
            )
            try secretStore.save(
                secret: secret,
                account: backendSecretAccount,
                authenticationPolicy: .failIfInteractionNeeded
            )
            try database.saveRepository(repository)
            try database.saveProfile(profile)
            try database.saveJobRun(job)
            try database.saveSnapshot(snapshot, repositoryID: repositoryID)
            print("Seeded diagnostic acceptance state and throwaway Keychain items.")
            exit(0)
        } catch {
            fputs("Delta diagnostic acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceLocalLifecycle() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_LOCAL_LIFECYCLE_ACCEPTANCE"] == "1" else {
            fputs("Delta local lifecycle acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptanceLocalLifecycleCommand.run(executableURL: selfExecutableURL())
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta local lifecycle acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceRunControl() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_RUN_CONTROL_ACCEPTANCE"] == "1" else {
            fputs("Delta run-control acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptanceRunControlCommand.run()
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta run-control acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceExternalLifecycle() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_EXTERNAL_LIFECYCLE_ACCEPTANCE"] == "1" else {
            fputs("Delta external lifecycle acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptanceExternalLifecycleCommand.run(executableURL: selfExecutableURL())
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta external lifecycle acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceExternalPreflight() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_EXTERNAL_PREFLIGHT_ACCEPTANCE"] == "1" else {
            fputs("Delta external preflight acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let environment = ProcessInfo.processInfo.environment
            let results = try ExternalBackendAcceptancePreflight.results(environment: environment)
            let report = try ExternalBackendAcceptancePreflight.markdownReport(environment: environment)
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            if ExternalBackendAcceptancePreflight.hasInvalidConfiguration(results)
                || ExternalBackendAcceptancePreflight.hasUnreadyRequestedConfiguration(results, environment: environment) {
                exit(1)
            }
            exit(0)
        } catch {
            fputs("Delta external preflight acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptancePreferences() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_PREFERENCES_ACCEPTANCE"] == "1" else {
            fputs("Delta preferences acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptancePreferencesCommand.run()
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta preferences acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceMenuBarSurface() -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_MENU_BAR_ACCEPTANCE"] == "1" else {
            fputs("Delta menu bar acceptance command is disabled.\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptanceMenuBarSurfaceCommand.run()
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta menu bar acceptance error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceSeedScheduledAgent(arguments: [String]) -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_SCHEDULED_AGENT_ACCEPTANCE"] == "1" else {
            fputs("Delta scheduled agent acceptance command is disabled.\n", stderr)
            exit(64)
        }
        guard arguments.count == 2 else {
            fputs("usage: Delta --acceptance-seed-scheduled-agent <work-directory> <keychain-account>\n", stderr)
            exit(64)
        }

        do {
            let output = try AcceptanceScheduledAgentCommand.seed(
                workDirectory: URL(fileURLWithPath: arguments[0]),
                keychainAccount: arguments[1]
            )
            print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta scheduled agent acceptance seed error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runAcceptanceVerifyScheduledAgent(arguments: [String]) -> Never {
        guard ProcessInfo.processInfo.environment["DELTA_ENABLE_SCHEDULED_AGENT_ACCEPTANCE"] == "1" else {
            fputs("Delta scheduled agent acceptance command is disabled.\n", stderr)
            exit(64)
        }
        guard arguments.count == 2 else {
            fputs("usage: Delta --acceptance-verify-scheduled-agent <work-directory> <keychain-account>\n", stderr)
            exit(64)
        }

        do {
            let report = try AcceptanceScheduledAgentCommand.verify(
                workDirectory: URL(fileURLWithPath: arguments[0]),
                keychainAccount: arguments[1]
            )
            print(report, terminator: report.hasSuffix("\n") ? "" : "\n")
            exit(0)
        } catch {
            fputs("Delta scheduled agent acceptance verify error: \(error.localizedDescription)\n", stderr)
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
