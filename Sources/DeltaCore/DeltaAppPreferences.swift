import Foundation

public enum DeltaAppPreferenceKeys {
    public static let acknowledgedBackupIssueFingerprints = "Delta.acknowledgedBackupIssueFingerprints"
    public static let backupFreshnessWarningHours = "Delta.backupFreshnessWarningHours"
    public static let destinationFreeSpaceWarningGiB = "Delta.destinationFreeSpaceWarningGiB"
    public static let destinationVerificationWarningHours = "Delta.destinationVerificationWarningHours"
    public static let defaultProfileCatchUpMissedRuns = "Delta.defaultProfileCatchUpMissedRuns"
    public static let defaultProfileCheckAfterPrune = "Delta.defaultProfileCheckAfterPrune"
    public static let defaultProfileDownloadLimitKiB = "Delta.defaultProfileDownloadLimitKiB"
    public static let defaultProfileKeepDaily = "Delta.defaultProfileKeepDaily"
    public static let defaultProfileKeepHourly = "Delta.defaultProfileKeepHourly"
    public static let defaultProfileKeepMonthly = "Delta.defaultProfileKeepMonthly"
    public static let defaultProfileKeepWeekly = "Delta.defaultProfileKeepWeekly"
    public static let defaultProfileKeepYearly = "Delta.defaultProfileKeepYearly"
    public static let defaultProfileMaintenanceEnabled = "Delta.defaultProfileMaintenanceEnabled"
    public static let defaultProfileMaintenanceHour = "Delta.defaultProfileMaintenanceHour"
    public static let defaultProfileMaintenanceIntervalDays = "Delta.defaultProfileMaintenanceIntervalDays"
    public static let defaultProfileMaintenanceMinute = "Delta.defaultProfileMaintenanceMinute"
    public static let defaultProfilePruneAfterForget = "Delta.defaultProfilePruneAfterForget"
    public static let defaultProfileRunInLowPowerMode = "Delta.defaultProfileRunInLowPowerMode"
    public static let defaultProfileRunOnBattery = "Delta.defaultProfileRunOnBattery"
    public static let defaultProfileScheduleDay = "Delta.defaultProfileScheduleDay"
    public static let defaultProfileScheduleEnabled = "Delta.defaultProfileScheduleEnabled"
    public static let defaultProfileScheduleHour = "Delta.defaultProfileScheduleHour"
    public static let defaultProfileScheduleIntervalMinutes = "Delta.defaultProfileScheduleIntervalMinutes"
    public static let defaultProfileScheduleKind = "Delta.defaultProfileScheduleKind"
    public static let defaultProfileScheduleMinute = "Delta.defaultProfileScheduleMinute"
    public static let defaultProfileScheduleWeekday = "Delta.defaultProfileScheduleWeekday"
    public static let defaultProfileUploadLimitKiB = "Delta.defaultProfileUploadLimitKiB"
    public static let defaultRestoreConflictPolicy = "Delta.defaultRestoreConflictPolicy"
    public static let operationalHistoryRetentionDays = "Delta.operationalHistoryRetentionDays"
    public static let pausesScheduledBackups = "Delta.pausesScheduledBackups"
    public static let preventsIdleSleepDuringJobs = "Delta.preventsIdleSleepDuringJobs"
    public static let previewsRestoresByDefault = "Delta.previewsRestoresByDefault"
    public static let scheduledBackupServiceFingerprint = "Delta.scheduledBackupServiceFingerprint"
    public static let sendsJobNotifications = "Delta.sendsJobNotifications"
    public static let sendsSuccessfulBackupNotifications = "Delta.sendsSuccessfulBackupNotifications"
    public static let showsMenuBarExtra = "Delta.showsMenuBarExtra"
    public static let updateCheckIntervalSeconds = "Delta.updateCheckIntervalSeconds"
    public static let verifiesRestoresByDefault = "Delta.verifiesRestoresByDefault"

    public static let backupProfileDefaults = [
        defaultProfileCatchUpMissedRuns,
        defaultProfileScheduleEnabled,
        defaultProfileScheduleKind,
        defaultProfileScheduleHour,
        defaultProfileScheduleMinute,
        defaultProfileScheduleWeekday,
        defaultProfileScheduleDay,
        defaultProfileScheduleIntervalMinutes,
        defaultProfileRunOnBattery,
        defaultProfileRunInLowPowerMode,
        defaultProfilePruneAfterForget,
        defaultProfileCheckAfterPrune,
        defaultProfileUploadLimitKiB,
        defaultProfileDownloadLimitKiB,
        defaultProfileKeepHourly,
        defaultProfileKeepDaily,
        defaultProfileKeepWeekly,
        defaultProfileKeepMonthly,
        defaultProfileKeepYearly,
        defaultProfileMaintenanceEnabled,
        defaultProfileMaintenanceIntervalDays,
        defaultProfileMaintenanceHour,
        defaultProfileMaintenanceMinute
    ]

    public static let restoreDefaults = [
        previewsRestoresByDefault,
        verifiesRestoresByDefault,
        defaultRestoreConflictPolicy
    ]

    public static let healthMonitoring = [
        backupFreshnessWarningHours,
        destinationFreeSpaceWarningGiB,
        destinationVerificationWarningHours
    ]

    public static let appBehavior = [
        acknowledgedBackupIssueFingerprints,
        operationalHistoryRetentionDays,
        pausesScheduledBackups,
        preventsIdleSleepDuringJobs,
        sendsJobNotifications,
        sendsSuccessfulBackupNotifications,
        showsMenuBarExtra,
        updateCheckIntervalSeconds
    ]

    public static let all = backupProfileDefaults + restoreDefaults + healthMonitoring + appBehavior
}

public enum DeltaAppPreferences {
    public static let sharedSuiteName = "com.delta.backup.preferences"

    public static func sharedStore() -> UserDefaults {
        UserDefaults(suiteName: sharedSuiteName) ?? .standard
    }

    public static func bool(for key: String, default defaultValue: Bool) -> Bool {
        if let storedValue = sharedStore().object(forKey: key) as? Bool {
            return storedValue
        }
        return defaultValue
    }

    public static func string(for key: String, default defaultValue: String) -> String {
        if let storedValue = sharedStore().string(forKey: key) {
            return storedValue
        }
        return defaultValue
    }

    public static func integer(for key: String, default defaultValue: Int) -> Int {
        if let storedValue = sharedStore().object(forKey: key) as? Int {
            return storedValue
        }
        return defaultValue
    }
}

public enum AppUpdateCheckInterval: Int, CaseIterable, Identifiable, Sendable {
    case daily = 86_400
    case weekly = 604_800
    case monthly = 2_592_000

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    public var summaryText: String {
        switch self {
        case .daily: "Checked daily"
        case .weekly: "Checked weekly"
        case .monthly: "Checked monthly"
        }
    }

    public static func normalized(_ rawValue: Int) -> AppUpdateCheckInterval {
        AppUpdateCheckInterval(rawValue: rawValue) ?? .daily
    }
}

public enum BackupFreshnessWarningThreshold: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 24
    case threeDays = 72
    case oneWeek = 168
    case thirtyDays = 720

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        case .thirtyDays: "30 days"
        }
    }

    public var summaryText: String {
        "Warn after \(title)"
    }

    public var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 3_600
    }

    public static func normalized(_ rawValue: Int) -> BackupFreshnessWarningThreshold {
        BackupFreshnessWarningThreshold(rawValue: rawValue) ?? .threeDays
    }
}

public enum DestinationVerificationWarningThreshold: Int, CaseIterable, Identifiable, Sendable {
    case oneWeek = 168
    case thirtyDays = 720
    case ninetyDays = 2_160

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oneWeek: "1 week"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }

    public var summaryText: String {
        "Warn after \(title)"
    }

    public var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 3_600
    }

    public static func normalized(_ rawValue: Int) -> DestinationVerificationWarningThreshold {
        DestinationVerificationWarningThreshold(rawValue: rawValue) ?? .thirtyDays
    }
}

public enum DestinationFreeSpaceWarningThreshold: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case tenGiB = 10
    case fiftyGiB = 50
    case oneHundredGiB = 100
    case twoHundredFiftyGiB = 250

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .tenGiB: "10 GB"
        case .fiftyGiB: "50 GB"
        case .oneHundredGiB: "100 GB"
        case .twoHundredFiftyGiB: "250 GB"
        }
    }

    public var summaryText: String {
        switch self {
        case .off:
            return "Off"
        default:
            return "Warn below \(title)"
        }
    }

    public var minimumBytes: Int64? {
        switch self {
        case .off:
            return nil
        default:
            return Int64(rawValue) * 1_024 * 1_024 * 1_024
        }
    }

    public static func normalized(_ rawValue: Int) -> DestinationFreeSpaceWarningThreshold {
        DestinationFreeSpaceWarningThreshold(rawValue: rawValue) ?? .fiftyGiB
    }
}

public enum OperationalHistoryRetention: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365
    case forever = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .oneYear: "1 year"
        case .forever: "Forever"
        }
    }

    public var summaryText: String {
        switch self {
        case .forever: "Keep forever"
        default: "Keep \(title)"
        }
    }

    public var cutoffInterval: TimeInterval? {
        switch self {
        case .forever:
            return nil
        default:
            return TimeInterval(rawValue) * 86_400
        }
    }

    public func cutoffDate(now: Date) -> Date? {
        cutoffInterval.map { now.addingTimeInterval(-$0) }
    }

    public static func normalized(_ rawValue: Int) -> OperationalHistoryRetention {
        OperationalHistoryRetention(rawValue: rawValue) ?? .ninetyDays
    }

    public static func current() -> OperationalHistoryRetention {
        normalized(
            DeltaAppPreferences.integer(
                for: DeltaAppPreferenceKeys.operationalHistoryRetentionDays,
                default: OperationalHistoryRetention.ninetyDays.rawValue
            )
        )
    }
}
