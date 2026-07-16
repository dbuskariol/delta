import Foundation

public enum DeltaAgentRunner {
    public static func runDueBackups(
        secretBridgeURL: URL,
        secretBridgeArguments: [String]
    ) throws -> Int32 {
        let database = try DeltaDatabase.live()
        let coordinator = BackupCoordinator(
            database: database,
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: ResticExecutableLocator().locate(),
                secretBridgeURL: secretBridgeURL,
                secretBridgeArguments: secretBridgeArguments,
                credentialResolver: RepositoryCredentialResolver(
                    authenticationPolicy: .failIfInteractionNeeded
                )
            ),
            runControlStore: ResticRunControlStore()
        )

        _ = try coordinator.recoverAbandonedRunningJobs()
        let runs = try coordinator.runDueBackups()
        try notifyCompletedJobs(runs, database: database)
        pruneOperationalHistory(database: database)
        print("DeltaAgent completed \(runs.count) due backup run(s).")
        return runs.contains(where: { $0.status == .failed }) ? 1 : 0
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
        let acknowledgmentStore = BackupIssueAcknowledgmentStore()
        for job in jobs {
            let issues = (try? database.fetchBackupIssues(jobID: job.id)) ?? []
            let warningIssuesAreAcknowledged = job.profileID.map {
                acknowledgmentStore.allAcknowledged(issues, profileID: $0)
            } ?? false
            guard let content = JobNotificationPolicy.content(
                for: job,
                settings: settings,
                profileName: job.profileID.flatMap { profilesByID[$0] },
                repositoryName: repositoriesByID[job.repositoryID],
                warningIssuesAreAcknowledged: warningIssuesAreAcknowledged
            ) else {
                continue
            }
            switch DeltaUserNotifier.deliverAndWait(content) {
            case .delivered:
                break
            case let .failed(detail):
                try? database.appendEvent(
                    EventLog(
                        level: .warning,
                        message: "Scheduled job notification could not be delivered: \(detail)"
                    )
                )
            case .timedOut:
                try? database.appendEvent(
                    EventLog(
                        level: .warning,
                        message: "Scheduled job notification delivery timed out. Open Delta and review notification access in Settings."
                    )
                )
            }
        }
    }

    private static func pruneOperationalHistory(database: DeltaDatabase) {
        do {
            let result = try OperationalHistoryMaintenance.prune(database: database)
            if result.totalDeleted > 0 {
                try? database.appendEvent(
                    EventLog(
                        level: .info,
                        message: "Activity history cleanup removed \(result.totalDeleted) old \(result.totalDeleted == 1 ? "item" : "items") from Delta's local database."
                    )
                )
            }
        } catch {
            try? database.appendEvent(
                EventLog(
                    level: .warning,
                    message: "Could not clean up old activity history: \(error.localizedDescription)"
                )
            )
        }
    }
}
