import XCTest
@testable import DeltaCore

final class DeltaAppPreferencesTests: XCTestCase {
    private var sharedSuite: UserDefaults? {
        UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)
    }

    func testBoolReadsSharedSuiteAndIgnoresStandardDefaults() {
        let key = "Delta.test.\(UUID().uuidString)"
        sharedSuite?.set(true, forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: false))
    }

    func testBoolUsesSharedSuiteForHelperProcesses() {
        let key = "Delta.test.\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: key)
        sharedSuite?.set(true, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: false))
    }

    func testBoolUsesDefaultWhenUnset() {
        let key = "Delta.test.\(UUID().uuidString)"
        UserDefaults.standard.set(false, forKey: key)
        UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)?.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: true))
    }

    func testStringReadsSharedSuiteAndIgnoresStandardDefaults() {
        let key = "Delta.test.\(UUID().uuidString)"
        sharedSuite?.set("shared", forKey: key)
        UserDefaults.standard.set("standard", forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertEqual(DeltaAppPreferences.string(for: key, default: "fallback"), "shared")
    }

    func testStringUsesDefaultWhenOnlyStandardDefaultsContainsValue() {
        let key = "Delta.test.\(UUID().uuidString)"
        sharedSuite?.removeObject(forKey: key)
        UserDefaults.standard.set("standard", forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertEqual(DeltaAppPreferences.string(for: key, default: "fallback"), "fallback")
    }

    func testIntegerReadsSharedSuiteAndIgnoresStandardDefaults() {
        let key = "Delta.test.\(UUID().uuidString)"
        sharedSuite?.set(42, forKey: key)
        UserDefaults.standard.set(7, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertEqual(DeltaAppPreferences.integer(for: key, default: 1), 42)
    }

    func testIntegerUsesDefaultWhenOnlyStandardDefaultsContainsValue() {
        let key = "Delta.test.\(UUID().uuidString)"
        sharedSuite?.removeObject(forKey: key)
        UserDefaults.standard.set(7, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
        }

        XCTAssertEqual(DeltaAppPreferences.integer(for: key, default: 1), 1)
    }

    func testSharedStoreWritesAreVisibleToPreferenceReaders() {
        let boolKey = "Delta.test.\(UUID().uuidString)"
        let stringKey = "Delta.test.\(UUID().uuidString)"
        let intKey = "Delta.test.\(UUID().uuidString)"
        DeltaAppPreferences.sharedStore().set(true, forKey: boolKey)
        DeltaAppPreferences.sharedStore().set("shared", forKey: stringKey)
        DeltaAppPreferences.sharedStore().set(86_400, forKey: intKey)
        defer {
            DeltaAppPreferences.sharedStore().removeObject(forKey: boolKey)
            DeltaAppPreferences.sharedStore().removeObject(forKey: stringKey)
            DeltaAppPreferences.sharedStore().removeObject(forKey: intKey)
            UserDefaults.standard.removeObject(forKey: boolKey)
            UserDefaults.standard.removeObject(forKey: stringKey)
            UserDefaults.standard.removeObject(forKey: intKey)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: boolKey, default: false))
        XCTAssertEqual(DeltaAppPreferences.string(for: stringKey, default: "fallback"), "shared")
        XCTAssertEqual(DeltaAppPreferences.integer(for: intKey, default: 0), 86_400)
    }

    func testIdleSleepProtectionPreferenceDefaultsToEnabled() {
        let key = DeltaAppPreferenceKeys.preventsIdleSleepDuringJobs
        let standardValue = UserDefaults.standard.object(forKey: key)
        let sharedValue = sharedSuite?.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        sharedSuite?.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
            if let standardValue {
                UserDefaults.standard.set(standardValue, forKey: key)
            }
            if let sharedValue {
                sharedSuite?.set(sharedValue, forKey: key)
            }
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: true))

        sharedSuite?.set(false, forKey: key)

        XCTAssertFalse(DeltaAppPreferences.bool(for: key, default: true))
    }

    func testScheduledBackupPausePreferenceDefaultsToRunning() {
        let key = DeltaAppPreferenceKeys.pausesScheduledBackups
        let standardValue = UserDefaults.standard.object(forKey: key)
        let sharedValue = sharedSuite?.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        sharedSuite?.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            sharedSuite?.removeObject(forKey: key)
            if let standardValue {
                UserDefaults.standard.set(standardValue, forKey: key)
            }
            if let sharedValue {
                sharedSuite?.set(sharedValue, forKey: key)
            }
        }

        XCTAssertFalse(DeltaAppPreferences.bool(for: key, default: false))

        sharedSuite?.set(true, forKey: key)

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: false))
    }

    func testUpdateCheckIntervalNormalizesUnsupportedValues() {
        XCTAssertEqual(AppUpdateCheckInterval.normalized(AppUpdateCheckInterval.daily.rawValue), .daily)
        XCTAssertEqual(AppUpdateCheckInterval.normalized(AppUpdateCheckInterval.weekly.rawValue), .weekly)
        XCTAssertEqual(AppUpdateCheckInterval.normalized(-1), .daily)
    }

    func testBackupFreshnessWarningThresholdNormalizesUnsupportedValues() {
        XCTAssertEqual(BackupFreshnessWarningThreshold.normalized(BackupFreshnessWarningThreshold.oneDay.rawValue), .oneDay)
        XCTAssertEqual(BackupFreshnessWarningThreshold.normalized(BackupFreshnessWarningThreshold.thirtyDays.rawValue), .thirtyDays)
        XCTAssertEqual(BackupFreshnessWarningThreshold.normalized(-1), .threeDays)
        XCTAssertEqual(BackupFreshnessWarningThreshold.threeDays.summaryText, "Warn after 3 days")
    }

    func testDestinationVerificationWarningThresholdNormalizesUnsupportedValues() {
        XCTAssertEqual(DestinationVerificationWarningThreshold.normalized(DestinationVerificationWarningThreshold.oneWeek.rawValue), .oneWeek)
        XCTAssertEqual(DestinationVerificationWarningThreshold.normalized(DestinationVerificationWarningThreshold.ninetyDays.rawValue), .ninetyDays)
        XCTAssertEqual(DestinationVerificationWarningThreshold.normalized(-1), .thirtyDays)
        XCTAssertEqual(DestinationVerificationWarningThreshold.thirtyDays.summaryText, "Warn after 30 days")
    }

    func testOperationalHistoryRetentionNormalizesUnsupportedValues() {
        XCTAssertEqual(OperationalHistoryRetention.normalized(OperationalHistoryRetention.sevenDays.rawValue), .sevenDays)
        XCTAssertEqual(OperationalHistoryRetention.normalized(OperationalHistoryRetention.forever.rawValue), .forever)
        XCTAssertEqual(OperationalHistoryRetention.normalized(-1), .ninetyDays)
        XCTAssertEqual(OperationalHistoryRetention.ninetyDays.summaryText, "Keep 90 days")
        XCTAssertEqual(OperationalHistoryRetention.forever.summaryText, "Keep forever")
    }

    func testOperationalHistoryRetentionComputesCutoffDate() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)

        let cutoff = try XCTUnwrap(OperationalHistoryRetention.sevenDays.cutoffDate(now: now))

        XCTAssertEqual(cutoff, now.addingTimeInterval(-7 * 86_400))
        XCTAssertNil(OperationalHistoryRetention.forever.cutoffDate(now: now))
    }

    func testBackupProfileDefaultsUseRecommendedPolicyWhenUnset() {
        withClearedBackupProfileDefaults {
            let schedule = BackupProfileDefaults.schedule()
            let retention = BackupProfileDefaults.retention()

            XCTAssertTrue(schedule.catchUpMissedRuns)
            XCTAssertTrue(schedule.runOnBattery)
            XCTAssertFalse(schedule.runInLowPowerMode)
            XCTAssertNil(schedule.uploadLimitKiB)
            XCTAssertNil(schedule.downloadLimitKiB)
            XCTAssertTrue(retention.pruneAfterForget)
            XCTAssertTrue(retention.checkAfterPrune)
            XCTAssertTrue(retention.maintenanceSchedule.isEnabled)
            XCTAssertEqual(retention.maintenanceSchedule.intervalDays, 7)
            XCTAssertEqual(retention.maintenanceSchedule.hour, 2)
            XCTAssertEqual(retention.maintenanceSchedule.minute, 0)
        }
    }

    func testBackupProfileDefaultsReadSharedSettingsForNewProfiles() {
        withClearedBackupProfileDefaults {
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileCatchUpMissedRuns)
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileRunOnBattery)
            sharedSuite?.set(true, forKey: DeltaAppPreferenceKeys.defaultProfileRunInLowPowerMode)
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.defaultProfilePruneAfterForget)
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileCheckAfterPrune)
            sharedSuite?.set(1_024, forKey: DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB)
            sharedSuite?.set(2_048, forKey: DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB)
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceEnabled)
            sharedSuite?.set(14, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays)
            sharedSuite?.set(3, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceHour)
            sharedSuite?.set(30, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute)

            let schedule = BackupProfileDefaults.schedule()
            let retention = BackupProfileDefaults.retention()

            XCTAssertFalse(schedule.catchUpMissedRuns)
            XCTAssertFalse(schedule.runOnBattery)
            XCTAssertTrue(schedule.runInLowPowerMode)
            XCTAssertEqual(schedule.uploadLimitKiB, 1_024)
            XCTAssertEqual(schedule.downloadLimitKiB, 2_048)
            XCTAssertFalse(retention.pruneAfterForget)
            XCTAssertFalse(retention.checkAfterPrune)
            XCTAssertFalse(retention.maintenanceSchedule.isEnabled)
            XCTAssertEqual(retention.maintenanceSchedule.intervalDays, 14)
            XCTAssertEqual(retention.maintenanceSchedule.hour, 3)
            XCTAssertEqual(retention.maintenanceSchedule.minute, 30)
        }
    }

    func testBackupProfileDefaultsNormalizeStoredMaintenanceValues() {
        withClearedBackupProfileDefaults {
            sharedSuite?.set(-1, forKey: DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB)
            sharedSuite?.set(0, forKey: DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB)
            sharedSuite?.set(0, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays)
            sharedSuite?.set(99, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceHour)
            sharedSuite?.set(-12, forKey: DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute)

            let schedule = BackupProfileDefaults.schedule()
            let retention = BackupProfileDefaults.retention()

            XCTAssertNil(schedule.uploadLimitKiB)
            XCTAssertNil(schedule.downloadLimitKiB)
            XCTAssertEqual(retention.maintenanceSchedule.intervalDays, 1)
            XCTAssertEqual(retention.maintenanceSchedule.hour, 23)
            XCTAssertEqual(retention.maintenanceSchedule.minute, 0)
        }
    }

    func testRestoreDefaultsUseRecommendedPolicyWhenUnset() {
        withClearedRestoreDefaults {
            let defaults = RestoreDefaults.current()

            XCTAssertTrue(defaults.previewFirst)
            XCTAssertTrue(defaults.verifyRestoredFiles)
            XCTAssertEqual(defaults.conflictPolicy, .ifChanged)
            XCTAssertEqual(defaults.summaryText, "Preview first, verify files, Replace changed")
        }
    }

    func testRestoreDefaultsReadSharedSettings() {
        withClearedRestoreDefaults {
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.previewsRestoresByDefault)
            sharedSuite?.set(false, forKey: DeltaAppPreferenceKeys.verifiesRestoresByDefault)
            sharedSuite?.set(RestoreConflictPolicy.never.rawValue, forKey: DeltaAppPreferenceKeys.defaultRestoreConflictPolicy)

            let defaults = RestoreDefaults.current()

            XCTAssertFalse(defaults.previewFirst)
            XCTAssertFalse(defaults.verifyRestoredFiles)
            XCTAssertEqual(defaults.conflictPolicy, .never)
            XCTAssertEqual(defaults.summaryText, "Direct restore, no verification, Keep existing")
        }
    }

    func testRestoreDefaultsNormalizeInvalidConflictPolicy() {
        let normalized = RestoreDefaults.normalized(
            previewFirst: false,
            verifyRestoredFiles: true,
            conflictPolicyRawValue: "invalid-policy"
        )

        XCTAssertFalse(normalized.previewFirst)
        XCTAssertTrue(normalized.verifyRestoredFiles)
        XCTAssertEqual(normalized.conflictPolicy, .ifChanged)

        withClearedRestoreDefaults {
            sharedSuite?.set("invalid-policy", forKey: DeltaAppPreferenceKeys.defaultRestoreConflictPolicy)

            XCTAssertEqual(RestoreDefaults.current().conflictPolicy, .ifChanged)
        }
    }

    private func withClearedBackupProfileDefaults(_ body: () -> Void) {
        let keys = [
            DeltaAppPreferenceKeys.defaultProfileCatchUpMissedRuns,
            DeltaAppPreferenceKeys.defaultProfileRunOnBattery,
            DeltaAppPreferenceKeys.defaultProfileRunInLowPowerMode,
            DeltaAppPreferenceKeys.defaultProfilePruneAfterForget,
            DeltaAppPreferenceKeys.defaultProfileCheckAfterPrune,
            DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB,
            DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB,
            DeltaAppPreferenceKeys.defaultProfileMaintenanceEnabled,
            DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays,
            DeltaAppPreferenceKeys.defaultProfileMaintenanceHour,
            DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute
        ]
        let standardValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = UserDefaults.standard.object(forKey: key)
        }
        let sharedValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = sharedSuite?.object(forKey: key)
        }
        keys.forEach {
            UserDefaults.standard.removeObject(forKey: $0)
            sharedSuite?.removeObject(forKey: $0)
        }
        defer {
            keys.forEach {
                UserDefaults.standard.removeObject(forKey: $0)
                sharedSuite?.removeObject(forKey: $0)
            }
            standardValues.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
            sharedValues.forEach { sharedSuite?.set($0.value, forKey: $0.key) }
        }

        body()
    }

    private func withClearedRestoreDefaults(_ body: () -> Void) {
        let keys = [
            DeltaAppPreferenceKeys.previewsRestoresByDefault,
            DeltaAppPreferenceKeys.verifiesRestoresByDefault,
            DeltaAppPreferenceKeys.defaultRestoreConflictPolicy
        ]
        let standardValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = UserDefaults.standard.object(forKey: key)
        }
        let sharedValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = sharedSuite?.object(forKey: key)
        }
        keys.forEach {
            UserDefaults.standard.removeObject(forKey: $0)
            sharedSuite?.removeObject(forKey: $0)
        }
        defer {
            keys.forEach {
                UserDefaults.standard.removeObject(forKey: $0)
                sharedSuite?.removeObject(forKey: $0)
            }
            standardValues.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
            sharedValues.forEach { sharedSuite?.set($0.value, forKey: $0.key) }
        }

        body()
    }
}
