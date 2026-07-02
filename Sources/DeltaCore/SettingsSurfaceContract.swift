import Foundation

public enum SettingsSurfaceContract {
    public static let categoryGeneral = "General"
    public static let categoryDefaults = "Defaults"
    public static let categoryUpdates = "Updates"
    public static let categoryAdvanced = "Advanced"

    public static let categoryTitles = [
        categoryGeneral,
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
        "Scheduled Backups",
        "App Behavior",
        "Backup & Restore Defaults",
        "Updates",
        "Support"
    ]

    public static let cardTitles = [
        "Scheduled Backups",
        "Password Access",
        "Full Disk Access",
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
        "Activity log detail",
        "History retention"
    ]

    public static let actionTitles = [
        "Run Due Now",
        "Review Login Items",
        "Refresh",
        "Repair Password Access",
        "Open Privacy Settings",
        "Show Delta",
        "Recheck",
        "Open Login Items",
        "Refresh Status",
        "Send Test Alert",
        "Request Permission",
        "Open Notifications",
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
        "Runs while Delta is closed",
        "No admin privileges",
        "Checks policy first"
    ]

    public static let requiredManualAcceptanceCoverage = [
        "Plain-language Scheduled Backups status",
        "Password access repair",
        "Compact status summary",
        "Run Due Now scheduler action",
        "Start at Login separate from Scheduled Backups",
        "Sparkle automatic check and download controls",
        "Idle-sleep protection",
        "Reset controls for recommended backup and restore defaults",
        "Backup freshness warning control",
        "Source access warning visibility through dashboard health",
        "Destination check warning control",
        "Destination free-space warning control",
        "Activity history retention"
    ]

    public static let forbiddenVisibleTerms = [
        "Launch" + "Agent",
        "Launch " + "Agent",
        "SMAppService" + "Status",
        "raw" + "Value",
        "Background " + "Backups",
        "Register",
        "Unregister"
    ]

    public static func validationFailures() -> [String] {
        var failures: [String] = []
        require(categoryTitles, contains: categoryGeneral, in: "categories", failures: &failures)
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
        require(cardTitles, contains: "Password Access", in: "cards", failures: &failures)
        require(cardTitles, contains: "Full Disk Access", in: "cards", failures: &failures)
        require(cardTitles, contains: "Power & Reliability", in: "cards", failures: &failures)
        require(cardTitles, contains: "Automatic Updates", in: "cards", failures: &failures)
        require(cardTitles, contains: "Diagnostics", in: "cards", failures: &failures)
        require(controlTitles, contains: "Pause automatic runs", in: "controls", failures: &failures)
        require(controlTitles, contains: "Backup freshness", in: "controls", failures: &failures)
        require(controlTitles, contains: "Destination checks", in: "controls", failures: &failures)
        require(controlTitles, contains: "Destination free space", in: "controls", failures: &failures)
        require(controlTitles, contains: "Activity log detail", in: "controls", failures: &failures)
        require(controlTitles, contains: "History retention", in: "controls", failures: &failures)
        require(actionTitles, contains: "Run Due Now", in: "actions", failures: &failures)
        require(actionTitles, contains: "Repair Password Access", in: "actions", failures: &failures)
        require(actionTitles, contains: "Restore Recommended", in: "actions", failures: &failures)
        require(actionTitles, contains: "Check Now", in: "actions", failures: &failures)
        require(actionTitles, contains: "Send Test Alert", in: "actions", failures: &failures)
        require(actionTitles, contains: "Copy Report", in: "actions", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Source access warning visibility through dashboard health", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Password access repair", in: "manual coverage", failures: &failures)
        require(requiredManualAcceptanceCoverage, contains: "Destination free-space warning control", in: "manual coverage", failures: &failures)

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
