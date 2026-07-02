import Foundation

public enum BackupProfileDefaults {
    public static func schedule() -> BackupSchedule {
        BackupSchedule(
            catchUpMissedRuns: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfileCatchUpMissedRuns,
                default: true
            ),
            runOnBattery: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfileRunOnBattery,
                default: true
            ),
            runInLowPowerMode: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfileRunInLowPowerMode,
                default: false
            )
        )
    }

    public static func retention() -> RetentionPolicy {
        RetentionPolicy(
            pruneAfterForget: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfilePruneAfterForget,
                default: true
            ),
            checkAfterPrune: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfileCheckAfterPrune,
                default: true
            )
        )
    }
}
