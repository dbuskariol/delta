import Foundation

public enum DefaultBackupScheduleKind: String, CaseIterable, Sendable {
    case hourly
    case daily
    case weekly
    case monthly
    case custom

    public static func normalized(_ rawValue: String) -> DefaultBackupScheduleKind {
        DefaultBackupScheduleKind(rawValue: rawValue) ?? .daily
    }
}

public enum BackupProfileDefaults {
    public static func schedule() -> BackupSchedule {
        BackupSchedule(
            kind: scheduleKind(),
            isEnabled: DeltaAppPreferences.bool(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleEnabled,
                default: true
            ),
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
            keepHourly: clamped(
                DeltaAppPreferences.integer(
                    for: DeltaAppPreferenceKeys.defaultProfileKeepHourly,
                    default: 24
                ),
                to: 0...168
            ),
            keepDaily: clamped(
                DeltaAppPreferences.integer(
                    for: DeltaAppPreferenceKeys.defaultProfileKeepDaily,
                    default: 30
                ),
                to: 0...365
            ),
            keepWeekly: clamped(
                DeltaAppPreferences.integer(
                    for: DeltaAppPreferenceKeys.defaultProfileKeepWeekly,
                    default: 12
                ),
                to: 0...260
            ),
            keepMonthly: clamped(
                DeltaAppPreferences.integer(
                    for: DeltaAppPreferenceKeys.defaultProfileKeepMonthly,
                    default: 12
                ),
                to: 0...120
            ),
            keepYearly: clamped(
                DeltaAppPreferences.integer(
                    for: DeltaAppPreferenceKeys.defaultProfileKeepYearly,
                    default: 0
                ),
                to: 0...50
            ),
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

    private static func scheduleKind() -> ScheduleKind {
        let kind = DefaultBackupScheduleKind.normalized(
            DeltaAppPreferences.string(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleKind,
                default: DefaultBackupScheduleKind.daily.rawValue
            )
        )
        let hour = clamped(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleHour,
                default: 20
            ),
            to: 0...23
        )
        let minute = clamped(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleMinute,
                default: 0
            ),
            to: 0...59
        )
        let weekday = clamped(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleWeekday,
                default: 2
            ),
            to: 1...7
        )
        let day = clamped(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleDay,
                default: 1
            ),
            to: 1...31
        )
        let intervalMinutes = clamped(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.defaultProfileScheduleIntervalMinutes,
                default: 120
            ),
            to: 1...10_080
        )

        switch kind {
        case .hourly:
            return .hourly(minute: minute)
        case .daily:
            return .daily(hour: hour, minute: minute)
        case .weekly:
            return .weekly(weekday: weekday, hour: hour, minute: minute)
        case .monthly:
            return .monthly(day: day, hour: hour, minute: minute)
        case .custom:
            return .customInterval(seconds: TimeInterval(intervalMinutes * 60))
        }
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
