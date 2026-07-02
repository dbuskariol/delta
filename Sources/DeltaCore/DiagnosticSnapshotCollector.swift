import Foundation

public struct DiagnosticSnapshotCollector {
    public var database: DeltaDatabase
    public var bundle: Bundle

    public init(database: DeltaDatabase, bundle: Bundle = .main) {
        self.database = database
        self.bundle = bundle
    }

    public func snapshot(activeOperation: String? = nil, fileManager: FileManager = .default) -> DiagnosticReportSnapshot {
        let info = bundle.infoDictionary ?? [:]
        let repositories = (try? database.fetchRepositories()) ?? []
        let profiles = (try? database.fetchProfiles()) ?? []
        let snapshots = (try? database.fetchSnapshots()) ?? []
        let jobs = (try? database.fetchJobRuns(limit: 100)) ?? []
        let resticURL = ResticExecutableLocator().locate(in: bundle)
        let rcloneURL = resticURL.deletingLastPathComponent().appendingPathComponent("rclone")
        let fullDiskAccessStatus = FullDiskAccessProbe().check(fileManager: fileManager)
        let backgroundPasswordSummary = BackgroundSecretAccessSummary(
            reports: repositories.map { RepositorySecretAccessRepairer().verify(repository: $0) },
            destinationCount: repositories.count
        )
        let recentJobs = jobs
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .map {
                DiagnosticJobSummary(
                    kind: $0.kind.displayName,
                    status: $0.status.displayName,
                    startedAt: $0.startedAt,
                    exitCode: $0.exitCode,
                    message: $0.message
                )
            }

        return DiagnosticReportSnapshot(
            generatedAt: Date(),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "Unknown",
            buildVersion: info["CFBundleVersion"] as? String ?? "Unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            bundlePath: bundle.bundleURL.path,
            executablePath: bundle.executableURL?.path ?? "Unknown",
            applicationSupportPath: diagnosticPath(fileManager: fileManager) { try AppDirectories.applicationSupportDirectory(fileManager: fileManager) },
            databasePath: diagnosticPath(fileManager: fileManager) { try AppDirectories.databaseURL(fileManager: fileManager) },
            logPath: diagnosticPath(fileManager: fileManager) { try AppDirectories.logDirectory(fileManager: fileManager) },
            fullDiskAccessStatus: fullDiskAccessStatus.hasLikelyFullDiskAccess ? "Ready" : "Needs Access",
            backgroundBackupsStatus: LaunchAgentController.status().displayName,
            scheduledAutomationStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.pausesScheduledBackups, default: false) ? "Paused" : "Running",
            backgroundPasswordAccessStatus: backgroundPasswordSummary.displayName,
            appLoginItemStatus: AppLoginItemController.status().displayName,
            notificationStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.sendsJobNotifications, default: false) ? "Enabled" : "Disabled",
            menuBarStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.showsMenuBarExtra, default: true) ? "Shown" : "Hidden",
            idleSleepProtectionStatus: DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs, default: true) ? "Enabled" : "Disabled",
            operationalHistoryRetentionStatus: OperationalHistoryRetention.current().summaryText,
            backupFreshnessStatus: BackupFreshnessWarningThreshold
                .normalized(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.backupFreshnessWarningHours,
                        default: BackupFreshnessWarningThreshold.threeDays.rawValue
                    )
                )
                .summaryText,
            destinationVerificationStatus: DestinationVerificationWarningThreshold
                .normalized(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.destinationVerificationWarningHours,
                        default: DestinationVerificationWarningThreshold.thirtyDays.rawValue
                    )
                )
                .summaryText,
            destinationFreeSpaceStatus: DestinationFreeSpaceWarningThreshold
                .normalized(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.destinationFreeSpaceWarningGiB,
                        default: DestinationFreeSpaceWarningThreshold.fiftyGiB.rawValue
                    )
                )
                .summaryText,
            restoreDefaultsStatus: RestoreDefaults.current().summaryText,
            activeOperation: activeOperation,
            profileCount: profiles.count,
            destinationCount: repositories.count,
            restorePointCount: snapshots.count,
            recentJobCount: jobs.count,
            tools: [
                DiagnosticToolSummary(
                    name: "restic",
                    path: resticURL.path,
                    isExecutable: fileManager.isExecutableFile(atPath: resticURL.path)
                ),
                DiagnosticToolSummary(
                    name: "rclone",
                    path: rcloneURL.path,
                    isExecutable: fileManager.isExecutableFile(atPath: rcloneURL.path)
                )
            ],
            destinations: repositories.map {
                DiagnosticDestinationSummary(
                    name: $0.name,
                    kind: $0.backend.kind.displayName,
                    lastVerifiedAt: $0.lastVerifiedAt
                )
            },
            profiles: profiles.map {
                DiagnosticProfileSummary(
                    name: $0.name,
                    sourceMode: $0.sourceMode.displayName,
                    sourceCount: $0.sources.count,
                    scheduleEnabled: $0.schedule.isEnabled,
                    customExcludeCount: BackupExcludePatternParser.customPatterns(from: $0.excludePatterns).count
                )
            },
            recentJobs: Array(recentJobs)
        )
    }

    private func diagnosticPath(fileManager: FileManager, _ resolve: () throws -> URL) -> String {
        do {
            return try resolve().path
        } catch {
            return "Unavailable: \(error.localizedDescription)"
        }
    }
}
