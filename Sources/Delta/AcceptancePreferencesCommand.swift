import DeltaCore
import Foundation

enum AcceptancePreferencesCommand {
    static func run(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("delta-preferences-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let store = DeltaAppPreferences.sharedStore()
        let snapshot = PreferenceSnapshot.capture(keys: DeltaAppPreferenceKeys.all, store: store)
        defer { snapshot.restore(to: store) }

        clearPreferences(in: store)
        try verifyRecommendedDefaults()
        try verifySettingsSurfaceContract()

        writeInvalidPreferences(to: store)
        try verifyInvalidPreferencesNormalize()

        clearPreferences(in: store)
        writeCustomPreferences(to: store)
        try verifyCustomDefaultsPersistThroughInstalledApp(root: root, bundle: bundle)

        return """
        # Delta Installed Preferences Acceptance

        - Generated: \(timestamp)
        - App: \(bundle.bundleURL.path)
        - Preference suite: \(DeltaAppPreferences.sharedSuiteName)
        - Isolated app support: \(try AppDirectories.applicationSupportDirectory(fileManager: fileManager).path)

        This verifies the installed Delta app reads Settings values from the shared preferences suite used by the UI and helper processes, exposes the required Settings categories and status summary contract, normalizes unsafe values, applies backup defaults to newly created profiles, applies restore defaults, and restores any existing user preferences after the probe.

        ## Result

        Installed preferences acceptance passed.

        - Recommended backup defaults: Verified
        - Recommended restore defaults: Verified
        - Settings surface contract: Verified
        - Settings categories: \(SettingsSurfaceContract.categoryTitles.joined(separator: ", "))
        - Settings status summary: \(SettingsSurfaceContract.statusSummaryTitles.joined(separator: ", "))
        - Settings manual coverage: \(SettingsSurfaceContract.requiredManualAcceptanceCoverage.joined(separator: ", "))
        - Invalid preference normalization: Verified
        - Custom backup defaults persisted to a new profile: Verified
        - Custom restore defaults: Verified
        - Diagnostic preference summary: Verified
        - Existing preference values restored on exit: Yes
        """
    }

    private static func clearPreferences(in store: UserDefaults) {
        for key in DeltaAppPreferenceKeys.all {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    private static func writeInvalidPreferences(to store: UserDefaults) {
        store.set(-1, forKey: DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB)
        store.set(0, forKey: DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB)
        store.set(-1, forKey: DeltaAppPreferenceKeys.defaultProfileKeepHourly)
        store.set(999, forKey: DeltaAppPreferenceKeys.defaultProfileKeepDaily)
        store.set(999, forKey: DeltaAppPreferenceKeys.defaultProfileKeepWeekly)
        store.set(999, forKey: DeltaAppPreferenceKeys.defaultProfileKeepMonthly)
        store.set(999, forKey: DeltaAppPreferenceKeys.defaultProfileKeepYearly)
        store.set(0, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays)
        store.set(99, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceHour)
        store.set(-12, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute)
        store.set("invalid-policy", forKey: DeltaAppPreferenceKeys.defaultRestoreConflictPolicy)
        store.set(-1, forKey: DeltaAppPreferenceKeys.backupFreshnessWarningHours)
        store.set(-1, forKey: DeltaAppPreferenceKeys.destinationVerificationWarningHours)
        store.set(-1, forKey: DeltaAppPreferenceKeys.operationalHistoryRetentionDays)
        store.set(-1, forKey: DeltaAppPreferenceKeys.updateCheckIntervalSeconds)
        store.synchronize()
    }

    private static func writeCustomPreferences(to store: UserDefaults) {
        store.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileCatchUpMissedRuns)
        store.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileRunOnBattery)
        store.set(true, forKey: DeltaAppPreferenceKeys.defaultProfileRunInLowPowerMode)
        store.set(false, forKey: DeltaAppPreferenceKeys.defaultProfilePruneAfterForget)
        store.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileCheckAfterPrune)
        store.set(1_024, forKey: DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB)
        store.set(2_048, forKey: DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB)
        store.set(48, forKey: DeltaAppPreferenceKeys.defaultProfileKeepHourly)
        store.set(60, forKey: DeltaAppPreferenceKeys.defaultProfileKeepDaily)
        store.set(26, forKey: DeltaAppPreferenceKeys.defaultProfileKeepWeekly)
        store.set(24, forKey: DeltaAppPreferenceKeys.defaultProfileKeepMonthly)
        store.set(7, forKey: DeltaAppPreferenceKeys.defaultProfileKeepYearly)
        store.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceEnabled)
        store.set(14, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays)
        store.set(3, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceHour)
        store.set(30, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute)
        store.set(false, forKey: DeltaAppPreferenceKeys.previewsRestoresByDefault)
        store.set(false, forKey: DeltaAppPreferenceKeys.verifiesRestoresByDefault)
        store.set(RestoreConflictPolicy.never.rawValue, forKey: DeltaAppPreferenceKeys.defaultRestoreConflictPolicy)
        store.set(BackupFreshnessWarningThreshold.oneWeek.rawValue, forKey: DeltaAppPreferenceKeys.backupFreshnessWarningHours)
        store.set(DestinationVerificationWarningThreshold.ninetyDays.rawValue, forKey: DeltaAppPreferenceKeys.destinationVerificationWarningHours)
        store.set(OperationalHistoryRetention.sevenDays.rawValue, forKey: DeltaAppPreferenceKeys.operationalHistoryRetentionDays)
        store.set(true, forKey: DeltaAppPreferenceKeys.pausesScheduledBackups)
        store.set(false, forKey: DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs)
        store.set(true, forKey: DeltaAppPreferenceKeys.sendsJobNotifications)
        store.set(true, forKey: DeltaAppPreferenceKeys.sendsSuccessfulBackupNotifications)
        store.set(false, forKey: DeltaAppPreferenceKeys.showsMenuBarExtra)
        store.set(AppUpdateCheckInterval.weekly.rawValue, forKey: DeltaAppPreferenceKeys.updateCheckIntervalSeconds)
        store.synchronize()
    }

    private static func verifyRecommendedDefaults() throws {
        let schedule = BackupProfileDefaults.schedule()
        let retention = BackupProfileDefaults.retention()
        let restore = RestoreDefaults.current()

        try require(schedule.kind == .daily(hour: 20, minute: 0), "Recommended schedule kind changed.")
        try require(schedule.isEnabled, "Recommended schedule should be enabled.")
        try require(schedule.catchUpMissedRuns, "Recommended schedule should catch up missed runs.")
        try require(schedule.runOnBattery, "Recommended schedule should allow battery runs.")
        try require(!schedule.runInLowPowerMode, "Recommended schedule should avoid Low Power Mode.")
        try require(schedule.uploadLimitKiB == nil, "Recommended upload speed limit should be unlimited.")
        try require(schedule.downloadLimitKiB == nil, "Recommended download speed limit should be unlimited.")
        try require(retention == RetentionPolicy(), "Recommended retention policy changed.")
        try require(restore == RestoreDefaults(), "Recommended restore defaults changed.")
        try require(BackupFreshnessWarningThreshold.normalized(-1) == .threeDays, "Backup freshness fallback changed.")
        try require(DestinationVerificationWarningThreshold.normalized(-1) == .thirtyDays, "Destination check fallback changed.")
        try require(OperationalHistoryRetention.normalized(-1) == .ninetyDays, "History retention fallback changed.")
        try require(AppUpdateCheckInterval.normalized(-1) == .daily, "Update interval fallback changed.")
        try require(!DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.pausesScheduledBackups, default: false), "Scheduled automation should default to running.")
        try require(DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs, default: true), "Idle sleep protection should default to enabled.")
        try require(DeltaAppPreferences.bool(for: DeltaAppPreferenceKeys.showsMenuBarExtra, default: true), "Status menu should default to shown.")
    }

    private static func verifySettingsSurfaceContract() throws {
        let failures = SettingsSurfaceContract.validationFailures()
        try require(failures.isEmpty, failures.joined(separator: " "))
    }

    private static func verifyInvalidPreferencesNormalize() throws {
        let schedule = BackupProfileDefaults.schedule()
        let retention = BackupProfileDefaults.retention()
        let restore = RestoreDefaults.current()

        try require(schedule.uploadLimitKiB == nil, "Invalid upload speed limit was not normalized.")
        try require(schedule.downloadLimitKiB == nil, "Invalid download speed limit was not normalized.")
        try require(retention.keepHourly == 0, "Hourly retention did not clamp to lower bound.")
        try require(retention.keepDaily == 365, "Daily retention did not clamp to upper bound.")
        try require(retention.keepWeekly == 260, "Weekly retention did not clamp to upper bound.")
        try require(retention.keepMonthly == 120, "Monthly retention did not clamp to upper bound.")
        try require(retention.keepYearly == 50, "Yearly retention did not clamp to upper bound.")
        try require(retention.maintenanceSchedule.intervalDays == 1, "Maintenance interval did not clamp to lower bound.")
        try require(retention.maintenanceSchedule.hour == 23, "Maintenance hour did not clamp to upper bound.")
        try require(retention.maintenanceSchedule.minute == 0, "Maintenance minute did not clamp to lower bound.")
        try require(restore.conflictPolicy == .ifChanged, "Invalid restore conflict policy did not normalize.")
        try require(BackupFreshnessWarningThreshold.normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.backupFreshnessWarningHours, default: -1)) == .threeDays, "Invalid backup freshness preference did not normalize.")
        try require(DestinationVerificationWarningThreshold.normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.destinationVerificationWarningHours, default: -1)) == .thirtyDays, "Invalid destination check preference did not normalize.")
        try require(OperationalHistoryRetention.current() == .ninetyDays, "Invalid history retention preference did not normalize.")
        try require(AppUpdateCheckInterval.normalized(DeltaAppPreferences.integer(for: DeltaAppPreferenceKeys.updateCheckIntervalSeconds, default: -1)) == .daily, "Invalid update interval did not normalize.")
    }

    private static func verifyCustomDefaultsPersistThroughInstalledApp(root: URL, bundle: Bundle) throws {
        let schedule = BackupProfileDefaults.schedule()
        let retention = BackupProfileDefaults.retention()
        let restore = RestoreDefaults.current()
        try requireCustomSchedule(schedule)
        try requireCustomRetention(retention)
        try require(restore == RestoreDefaults(previewFirst: false, verifyRestoredFiles: false, conflictPolicy: .never), "Custom restore defaults were not loaded.")

        let database = try DeltaDatabase.live()
        let repositoryID = UUID()
        let profileID = UUID()
        let repository = BackupRepository(
            id: repositoryID,
            name: "Preferences Acceptance Destination",
            backend: .local(path: root.appendingPathComponent("destination", isDirectory: true).path),
            keychainAccount: "preferences-acceptance-\(repositoryID.uuidString)"
        )
        let profile = BackupProfile(
            id: profileID,
            name: "Preferences Acceptance Profile",
            sourceMode: .customFolders,
            sources: [BackupSource(path: root.appendingPathComponent("source", isDirectory: true).path)],
            repositoryID: repositoryID,
            schedule: schedule,
            retention: retention
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        let storedProfile = try requireValue(
            database.fetchProfiles().first { $0.id == profileID },
            "Preference acceptance profile was not saved."
        )
        try requireCustomSchedule(storedProfile.schedule)
        try requireCustomRetention(storedProfile.retention)

        let diagnostic = DiagnosticSnapshotCollector(database: database, bundle: bundle).snapshot(fileManager: FileManager.default)
        try require(diagnostic.scheduledAutomationStatus == "Paused", "Diagnostics did not reflect paused scheduled automation.")
        try require(diagnostic.notificationStatus == "Enabled", "Diagnostics did not reflect notification preference.")
        try require(diagnostic.menuBarStatus == "Hidden", "Diagnostics did not reflect status menu preference.")
        try require(diagnostic.idleSleepProtectionStatus == "Disabled", "Diagnostics did not reflect idle sleep preference.")
        try require(diagnostic.operationalHistoryRetentionStatus == "Keep 7 days", "Diagnostics did not reflect history retention preference.")
        try require(diagnostic.backupFreshnessStatus == "Warn after 1 week", "Diagnostics did not reflect backup freshness preference.")
        try require(diagnostic.destinationVerificationStatus == "Warn after 90 days", "Diagnostics did not reflect destination verification preference.")
        try require(diagnostic.restoreDefaultsStatus == "Direct restore, no verification, Keep existing", "Diagnostics did not reflect restore defaults.")
    }

    private static func requireCustomSchedule(_ schedule: BackupSchedule) throws {
        try require(!schedule.catchUpMissedRuns, "Custom schedule should not catch up missed runs.")
        try require(!schedule.runOnBattery, "Custom schedule should not run on battery.")
        try require(schedule.runInLowPowerMode, "Custom schedule should run in Low Power Mode.")
        try require(schedule.uploadLimitKiB == 1_024, "Custom upload speed limit was not loaded.")
        try require(schedule.downloadLimitKiB == 2_048, "Custom download speed limit was not loaded.")
    }

    private static func requireCustomRetention(_ retention: RetentionPolicy) throws {
        try require(retention.keepHourly == 48, "Custom hourly retention was not loaded.")
        try require(retention.keepDaily == 60, "Custom daily retention was not loaded.")
        try require(retention.keepWeekly == 26, "Custom weekly retention was not loaded.")
        try require(retention.keepMonthly == 24, "Custom monthly retention was not loaded.")
        try require(retention.keepYearly == 7, "Custom yearly retention was not loaded.")
        try require(!retention.pruneAfterForget, "Custom cleanup compaction setting was not loaded.")
        try require(!retention.checkAfterPrune, "Custom post-cleanup verification setting was not loaded.")
        try require(!retention.maintenanceSchedule.isEnabled, "Custom maintenance enabled setting was not loaded.")
        try require(retention.maintenanceSchedule.intervalDays == 14, "Custom maintenance interval was not loaded.")
        try require(retention.maintenanceSchedule.hour == 3, "Custom maintenance hour was not loaded.")
        try require(retention.maintenanceSchedule.minute == 30, "Custom maintenance minute was not loaded.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw AcceptancePreferencesError.validationFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw AcceptancePreferencesError.validationFailed(message)
        }
        return value
    }
}

private struct PreferenceSnapshot {
    var storedValues: [String: Any]

    static func capture(keys: [String], store: UserDefaults) -> PreferenceSnapshot {
        PreferenceSnapshot(
            storedValues: keys.reduce(into: [String: Any]()) { values, key in
                if let value = store.object(forKey: key) {
                    values[key] = value
                }
            }
        )
    }

    func restore(to store: UserDefaults) {
        for key in DeltaAppPreferenceKeys.all {
            store.removeObject(forKey: key)
        }
        for (key, value) in storedValues {
            store.set(value, forKey: key)
        }
        store.synchronize()
    }
}

private enum AcceptancePreferencesError: Error, LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
