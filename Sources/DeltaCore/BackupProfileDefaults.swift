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
            ),
            uploadLimitKiB: optionalPositiveInteger(for: DeltaAppPreferenceKeys.defaultProfileUploadLimitKiB),
            downloadLimitKiB: optionalPositiveInteger(for: DeltaAppPreferenceKeys.defaultProfileDownloadLimitKiB)
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
            ),
            maintenanceSchedule: RetentionMaintenanceSchedule(
                isEnabled: DeltaAppPreferences.bool(
                    for: DeltaAppPreferenceKeys.defaultProfileMaintenanceEnabled,
                    default: true
                ),
                intervalDays: clamped(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.defaultProfileMaintenanceIntervalDays,
                        default: 7
                    ),
                    to: 1...90
                ),
                hour: clamped(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.defaultProfileMaintenanceHour,
                        default: 2
                    ),
                    to: 0...23
                ),
                minute: clamped(
                    DeltaAppPreferences.integer(
                        for: DeltaAppPreferenceKeys.defaultProfileMaintenanceMinute,
                        default: 0
                    ),
                    to: 0...59
                )
            )
        )
    }

    private static func optionalPositiveInteger(for key: String) -> Int? {
        let value = DeltaAppPreferences.integer(for: key, default: 0)
        guard value > 0 else {
            return nil
        }
        return clamped(value, to: 1...1_048_576)
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
