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

    func testUpdateCheckIntervalNormalizesUnsupportedValues() {
        XCTAssertEqual(AppUpdateCheckInterval.normalized(AppUpdateCheckInterval.daily.rawValue), .daily)
        XCTAssertEqual(AppUpdateCheckInterval.normalized(AppUpdateCheckInterval.weekly.rawValue), .weekly)
        XCTAssertEqual(AppUpdateCheckInterval.normalized(-1), .daily)
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
}
