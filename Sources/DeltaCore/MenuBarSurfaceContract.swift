import Foundation

public enum MenuBarSurfaceContract {
    public static let headerTitles = [
        "Delta",
        "Last Backup"
    ]

    public static let actionTitles = [
        "Back Up Now",
        "Run Due Backups",
        "Scheduled Paused",
        "Pause",
        "Stop",
        "Open",
        "Activity",
        "Refresh",
        "Updates",
        "Quit Delta"
    ]

    public static let statusTexts = [
        "Ready",
        "Backup running",
        "Restore running",
        "Last backup completed",
        "Last backup failed",
        "Last backup completed with warnings",
        "Last backup stopped",
        "Storage unavailable"
    ]

    public static let progressTexts = [
        "Preparing backup...",
        "Pausing safely...",
        "Stopping safely..."
    ]

    public static let capabilityTitles = [
        "Ready status",
        "Running status",
        "Attention status",
        "Pause backup",
        "Stop work",
        "Open Activity",
        "Check updates"
    ]

    public static let forbiddenVisibleTerms = [
        "Launch" + "Agent",
        "SMAppService",
        "raw" + "Value",
        "restic",
        "repository",
        "Succeeded"
    ]

    public static func validationFailures() -> [String] {
        var failures: [String] = []

        require(actionTitles, contains: "Back Up Now", in: "actions", failures: &failures)
        require(actionTitles, contains: "Run Due Backups", in: "actions", failures: &failures)
        require(actionTitles, contains: "Scheduled Paused", in: "actions", failures: &failures)
        require(actionTitles, contains: "Pause", in: "actions", failures: &failures)
        require(actionTitles, contains: "Stop", in: "actions", failures: &failures)
        require(actionTitles, contains: "Activity", in: "actions", failures: &failures)
        require(actionTitles, contains: "Updates", in: "actions", failures: &failures)
        require(actionTitles, contains: "Quit Delta", in: "actions", failures: &failures)
        require(statusTexts, contains: "Last backup completed", in: "statuses", failures: &failures)
        require(statusTexts, contains: "Last backup completed with warnings", in: "statuses", failures: &failures)
        require(progressTexts, contains: "Pausing safely...", in: "progress", failures: &failures)
        require(progressTexts, contains: "Stopping safely...", in: "progress", failures: &failures)

        let ready = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: nil
        )
        require(ready.headerText == "Ready", "Ready status should use concise product language.", failures: &failures)
        require(ready.badgeText == "Ready", "Ready badge should be stable.", failures: &failures)
        require(ready.symbolName == "externaldrive.badge.checkmark", "Ready symbol should match the status item icon.", failures: &failures)

        let activeBackup = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: true,
            activeJobKind: .backup,
            latestBackupStatus: .failed
        )
        require(activeBackup.headerText == "Backup running", "Active backup status should override stale job state.", failures: &failures)
        require(activeBackup.badgeText == "Running", "Active backup badge should show Running.", failures: &failures)

        let completedBackup = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )
        require(completedBackup.headerText == "Last backup completed", "Successful backup status should say completed, not succeeded.", failures: &failures)
        require(completedBackup.badgeText == "Ready", "Successful backup should return the menu bar to Ready.", failures: &failures)

        let warningBackup = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .warning
        )
        require(warningBackup.headerText == "Last backup completed with warnings", "Warning backup status should preserve warning context.", failures: &failures)
        require(warningBackup.badgeText == "Completed with warnings", "Warning backup badge should be explicit.", failures: &failures)

        let pausedSchedules = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: false,
            pausesScheduledBackups: true,
            activeJobKind: nil,
            activeStopRequest: nil
        )
        require(pausedSchedules.canBackUpNow, "Pause automatic runs should not disable manual Back Up Now.", failures: &failures)
        require(!pausedSchedules.canRunDueBackups, "Pause automatic runs should disable Run Due Backups.", failures: &failures)
        require(pausedSchedules.runDueTitle == "Scheduled Paused", "Paused schedule title should be concise.", failures: &failures)

        let activeAvailability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .backup,
            activeStopRequest: nil
        )
        require(!activeAvailability.canBackUpNow, "Active jobs should disable new manual backups.", failures: &failures)
        require(activeAvailability.canPauseActiveBackup, "Active backups should expose Pause.", failures: &failures)
        require(activeAvailability.canStopActiveJob, "Active jobs should expose Stop.", failures: &failures)

        for value in allVisibleStrings() where value.count > 42 {
            failures.append("Menu bar visible text is too long for the compact status menu: \(value)")
        }

        let visibleStrings = allVisibleStrings()
        for term in forbiddenVisibleTerms where visibleStrings.contains(where: { $0.localizedCaseInsensitiveContains(term) }) {
            failures.append("Menu bar contract exposes implementation or awkward status term '\(term)'.")
        }

        return failures
    }

    public static func allVisibleStrings() -> [String] {
        headerTitles
            + actionTitles
            + statusTexts
            + progressTexts
            + capabilityTitles
    }

    private static func require(
        _ values: [String],
        contains value: String,
        in group: String,
        failures: inout [String]
    ) {
        if !values.contains(value) {
            failures.append("Menu bar \(group) is missing '\(value)'.")
        }
    }

    private static func require(
        _ condition: Bool,
        _ message: String,
        failures: inout [String]
    ) {
        if !condition {
            failures.append(message)
        }
    }
}
