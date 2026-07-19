import Foundation

public enum SettingsLoginItemsActionPlacement: Equatable, Sendable {
    case timeMachineSystemSupport
    case scheduledBackups
    case hidden

    public static func resolve(
        timeMachineSystemSupportNeedsAttention: Bool,
        scheduledBackupsNeedAttention: Bool
    ) -> Self {
        if timeMachineSystemSupportNeedsAttention {
            return .timeMachineSystemSupport
        }
        if scheduledBackupsNeedAttention {
            return .scheduledBackups
        }
        return .hidden
    }
}

public enum SettingsSurfaceContract {
    public static let categoryGeneral = "General"
    public static let categoryPermissions = "Permissions"
    public static let categoryDefaults = "Defaults"
    public static let categoryUpdates = "Updates"
    public static let categoryAdvanced = "Advanced"

    public static let categoryTitles = [
        categoryGeneral,
        categoryPermissions,
        categoryDefaults,
        categoryUpdates,
        categoryAdvanced
    ]

    public static let statusSummaryTitles = [
        "System Access",
        "Schedules",
        "Passwords",
        "Updates",
        "Notifications",
        "Status Menu",
        "Backup Tools"
    ]

    public static let sectionTitles = [
        "App Behavior"
    ]

    public static let cardTitles = [
        "Scheduled Backups",
        "System Access",
        "Power & Reliability",
        "Menu Bar & Login",
        "Notifications",
        "Health Monitoring",
        "New Backup Defaults",
        "Restore Defaults",
        "Automatic Updates",
        "About Delta",
        "Backup Tools",
        "Support Files",
        "Diagnostics"
    ]

    public static let controlTitles = [
        "Allow scheduled backups",
        "Pause automatic runs",
        "Keep Mac awake during backup work",
        "Status menu",
        "Start Delta at login",
        "Job alerts",
        "Success summaries",
        "Backup freshness",
        "Destination checks",
        "Destination free space",
        "Schedule new profiles",
        "Default schedule",
        "Catch up missed runs",
        "Run on battery",
        "Run in Low Power Mode",
        "Free space after cleanup",
        "Verify after cleanup",
        "Default speed limits",
        "Default retention",
        "Automatic cleanup",
        "Cleanup cadence",
        "Preview first",
        "Verify files",
        "Existing files",
        "Automatic checks",
        "Check interval",
        "Download in background",
        "History retention"
    ]

    public static let actionTitles = [
        "Run Due Now",
        "Open Activity",
        "Review Login Items",
        "How Scheduled Backups Work",
        "Refresh",
        "Repair Password Access",
        "Review Permissions",
        "Allow Notifications",
        "System Settings",
        "Show Delta",
        "Open Login Items",
        "Open Login Items & Extensions",
        "Refresh Status",
        "Send Test Alert",
        "Restore Recommended",
        "Open Dashboard",
        "Manage Profiles",
        "Manage Destinations",
        "Check Now",
        "Show Tools",
        "Show App Data",
        "Show Logs",
        "Copy Report",
        "Export Report",
        "Clean Up Now"
    ]

    public static let capabilityTitles = [
        "Approved by macOS",
        "Runs while Delta is closed",
        "No admin privileges",
        "Checks policy first"
    ]

    public static let requiredManualAcceptanceCoverage = [
        "Plain-language Scheduled Backups status",
        "Plain-language scheduled backup explanation",
        "No raw system service terminology",
        "Scheduled Backups activity shortcut",
        "Password access repair",
        "Compact status summary",
        "Run Due Now scheduled-backup action",
        "Start at Login separate from Scheduled Backups",
        "One Login Items recovery action per settings context",
        "Category-specific File System Extensions approval guidance",
        "Sparkle automatic check and download controls",
        "Idle-sleep protection",
        "Expandable Scheduled Backups explanation",
        "Reset controls for recommended backup and restore defaults",
        "Configurable new-profile schedule defaults",
        "Backup freshness warning control",
        "Source access warning visibility through dashboard health",
        "Destination check warning control",
        "Destination free-space warning control",
        "Activity history retention"
    ]

    public static let forbiddenVisibleTerms = [
        "Launch" + "Agent",
        "Launch " + "Agent",
        "SMAppService",
        "SMAppService" + "Status",
        "raw" + "Value",
        "Background " + "Backups",
        "Missing " + "Scheduler",
        "Scheduler",
        "Register",
        "Unregister"
    ]

    public static func validationFailures() -> [String] {
        var failures: [String] = []
        require(categoryTitles, contains: categoryGeneral, in: "categories", failures: &failures)
        require(categoryTitles, contains: categoryPermissions, in: "categories", failures: &failures)
        require(categoryTitles, contains: categoryDefaults, in: "categories", failures: &failures)
        require(categoryTitles, contains: categoryUpdates, in: "categories", failures: &failures)
        require(categoryTitles, contains: categoryAdvanced, in: "categories", failures: &failures)
        require(statusSummaryTitles, contains: "System Access", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Schedules", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Passwords", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Updates", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Notifications", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Status Menu", in: "status summary", failures: &failures)
        require(statusSummaryTitles, contains: "Backup Tools", in: "status summary", failures: &failures)
        require(cardTitles, contains: "Scheduled Backups", in: "cards", failures: &failures)
        require(cardTitles, contains: "System Access", in: "cards", failures: &failures)
        require(cardTitles, contains: "Power & Reliability", in: "cards", failures: &failures)
        require(cardTitles, contains: "Automatic Updates", in: "cards", failures: &failures)
        require(cardTitles, contains: "Diagnostics", in: "cards", failures: &failures)
        require(controlTitles, contains: "Pause automatic runs", in: "controls", failures: &failures)
        require(controlTitles, contains: "Backup freshness", in: "controls", failures: &failures)
        require(controlTitles, contains: "Destination checks", in: "controls", failures: &failures)
        require(controlTitles, contains: "Destination free space", in: "controls", failures: &failures)
        require(controlTitles, contains: "Schedule new profiles", in: "controls", failures: &failures)
        require(controlTitles, contains: "Default schedule", in: "controls", failures: &failures)
        require(controlTitles, contains: "History retention", in: "controls", failures: &failures)
        require(actionTitles, contains: "Run Due Now", in: "actions", failures: &failures)
        require(actionTitles, contains: "Open Activity", in: "actions", failures: &failures)
        require(actionTitles, contains: "How Scheduled Backups Work", in: "actions", failures: &failures)
        require(actionTitles, contains: "Repair Password Access", in: "actions", failures: &failures)
        require(actionTitles, contains: "Restore Recommended", in: "actions", failures: &failures)
        require(actionTitles, contains: "Check Now", in: "actions", failures: &failures)
        require(actionTitles, contains: "Send Test Alert", in: "actions", failures: &failures)
        require(actionTitles, contains: "Copy Report", in: "actions", failures: &failures)
        require(actionTitles, contains: "Open Login Items & Extensions", in: "actions", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Source access warning visibility through dashboard health", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Plain-language scheduled backup explanation", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "No raw system service terminology", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Scheduled Backups activity shortcut", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Password access repair", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "One Login Items recovery action per settings context", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Category-specific File System Extensions approval guidance", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Destination free-space warning control", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Configurable new-profile schedule defaults", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Expandable Scheduled Backups explanation", in: "manual coverage", failures: &failures)

        let visibleStrings = allVisibleStrings()
        for term in forbiddenVisibleTerms where visibleStrings.contains(where: { $0.localizedCaseInsensitiveContains(term) }) {
            failures.append("Settings contract exposes implementation term '\(term)'.")
        }
        return failures
    }

    public static func allVisibleStrings() -> [String] {
        categoryTitles
            + statusSummaryTitles
            + sectionTitles
            + cardTitles
            + controlTitles
            + actionTitles
            + capabilityTitles
            + requiredManualAcceptanceCoverage
    }

    private static func require(
        _ values: [String],
        contains value: String,
        in group: String,
        failures: inout [String]
    ) {
        if !values.contains(value) {
            failures.append("Settings \(group) is missing '\(value)'.")
        }
    }
}
