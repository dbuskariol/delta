import Foundation

enum DeltaAppPreferenceKeys {
    static let activityLogDetail = "Delta.activityLogDetail"
    static let showsMenuBarExtra = "Delta.showsMenuBarExtra"
    static let updateCheckIntervalSeconds = "Delta.updateCheckIntervalSeconds"
}

enum DeltaAppPreferences {
    static func bool(for key: String, default defaultValue: Bool) -> Bool {
        guard let storedValue = UserDefaults.standard.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return storedValue
    }
}
