import Foundation

public enum DeltaAppPreferenceKeys {
    public static let activityLogDetail = "Delta.activityLogDetail"
    public static let defaultProfileCatchUpMissedRuns = "Delta.defaultProfileCatchUpMissedRuns"
    public static let defaultProfileCheckAfterPrune = "Delta.defaultProfileCheckAfterPrune"
    public static let defaultProfilePruneAfterForget = "Delta.defaultProfilePruneAfterForget"
    public static let defaultProfileRunInLowPowerMode = "Delta.defaultProfileRunInLowPowerMode"
    public static let defaultProfileRunOnBattery = "Delta.defaultProfileRunOnBattery"
    public static let defaultRestoreConflictPolicy = "Delta.defaultRestoreConflictPolicy"
    public static let previewsRestoresByDefault = "Delta.previewsRestoresByDefault"
    public static let sendsJobNotifications = "Delta.sendsJobNotifications"
    public static let sendsSuccessfulBackupNotifications = "Delta.sendsSuccessfulBackupNotifications"
    public static let showsMenuBarExtra = "Delta.showsMenuBarExtra"
    public static let updateCheckIntervalSeconds = "Delta.updateCheckIntervalSeconds"
    public static let verifiesRestoresByDefault = "Delta.verifiesRestoresByDefault"
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
