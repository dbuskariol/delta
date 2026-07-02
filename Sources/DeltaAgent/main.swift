import DeltaCore
import Foundation

enum DeltaAgentMain {
    static func run() -> Int32 {
        do {
            let database = try DeltaDatabase.live()
            let coordinator = BackupCoordinator(
                database: database,
                commandBuilder: ResticCommandBuilder(
                    resticExecutableURL: ResticExecutableLocator().locate(),
                    secretBridgeURL: secretBridgeURL(),
                    credentialResolver: RepositoryCredentialResolver(
                        authenticationPolicy: .failIfInteractionNeeded
                    )
                ),
                runControlStore: ResticRunControlStore()
            )

            if CommandLine.arguments.contains("--status") {
                print("DeltaAgent ready")
                return 0
            }

            _ = try coordinator.recoverAbandonedRunningJobs()
            let runs = try coordinator.runDueBackups()
            try notifyCompletedJobs(runs, database: database)
            print("DeltaAgent completed \(runs.count) due backup run(s).")
            return runs.contains(where: { $0.status == .failed }) ? 1 : 0
        } catch {
            fputs("DeltaAgent error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func secretBridgeURL() -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("DeltaSecretBridge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "DeltaSecretBridge") {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }

    private static func notifyCompletedJobs(_ jobs: [JobRun], database: DeltaDatabase) throws {
        let settings = JobNotificationSettings(
            isEnabled: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.sendsJobNotifications,
                default: false
            ),
            includesSuccessfulBackups: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.sendsSuccessfulBackupNotifications,
                default: false
            )
        )
        guard settings.isEnabled else {
            return
        }

        let profilesByID = Dictionary(uniqueKeysWithValues: try database.fetchProfiles().map { ($0.id, $0.name) })
        let repositoriesByID = Dictionary(uniqueKeysWithValues: try database.fetchRepositories().map { ($0.id, $0.name) })
        for job in jobs {
            guard let content = JobNotificationPolicy.content(
                for: job,
                settings: settings,
                profileName: job.profileID.flatMap { profilesByID[$0] },
                repositoryName: repositoriesByID[job.repositoryID]
            ) else {
                continue
            }
            DeltaUserNotifier.deliver(content)
        }
    }
}

exit(DeltaAgentMain.run())
