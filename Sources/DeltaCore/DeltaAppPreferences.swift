import Foundation

public enum DeltaAppPreferenceKeys {
    public static let activityLogDetail = "Delta.activityLogDetail"
    public static let defaultRestoreConflictPolicy = "Delta.defaultRestoreConflictPolicy"
    public static let previewsRestoresByDefault = "Delta.previewsRestoresByDefault"
    public static let sendsJobNotifications = "Delta.sendsJobNotifications"
    public static let sendsSuccessfulBackupNotifications = "Delta.sendsSuccessfulBackupNotifications"
    public static let showsMenuBarExtra = "Delta.showsMenuBarExtra"
    public static let updateCheckIntervalSeconds = "Delta.updateCheckIntervalSeconds"
    public static let verifiesRestoresByDefault = "Delta.verifiesRestoresByDefault"
}

public enum DeltaAppPreferences {
    public static let sharedSuiteName = "com.delta.backup"

    public static func bool(for key: String, default defaultValue: Bool) -> Bool {
        if let storedValue = UserDefaults(suiteName: sharedSuiteName)?.object(forKey: key) as? Bool {
            return storedValue
        }
        if let storedValue = UserDefaults.standard.object(forKey: key) as? Bool {
            return storedValue
        }
        return defaultValue
    }

    public static func string(for key: String, default defaultValue: String) -> String {
        if let storedValue = UserDefaults(suiteName: sharedSuiteName)?.string(forKey: key) {
            return storedValue
        }
        if let storedValue = UserDefaults.standard.string(forKey: key) {
            return storedValue
        }
        return defaultValue
    }
}
