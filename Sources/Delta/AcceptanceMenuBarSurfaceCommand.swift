import DeltaCore
import Foundation

enum AcceptanceMenuBarSurfaceCommand {
    static func run(bundle: Bundle = .main) throws -> String {
        let failures = MenuBarSurfaceContract.validationFailures()
        try require(failures.isEmpty, failures.joined(separator: " "))

        let ready = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: nil
        )
        let runningBackup = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: true,
            activeJobKind: .backup,
            latestBackupStatus: .failed
        )
        let runningRestore = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: true,
            activeJobKind: .restore,
            latestBackupStatus: .succeeded
        )
        let completed = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )
        let warning = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .warning
        )
        let failed = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .failed
        )
        let blocked = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: false,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )

        try require(ready.badgeText == "Ready", "Ready menu bar badge changed.")
        try require(runningBackup.headerText == "Backup running", "Active backup menu bar status changed.")
        try require(runningRestore.headerText == "Restore running", "Active restore menu bar status changed.")
        try require(completed.headerText == "Last backup completed", "Completed backup menu bar status changed.")
        try require(completed.badgeText == "Ready", "Completed backup should return the status badge to Ready.")
        try require(warning.badgeText == "Completed with warnings", "Warning backup badge changed.")
        try require(failed.badgeText == "Failed", "Failed backup badge changed.")
        try require(blocked.badgeText == "Blocked", "Blocked menu bar badge changed.")

        let paused = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: false,
            pausesScheduledBackups: true,
            activeJobKind: nil,
            activeStopRequest: nil
        )
        try require(paused.canBackUpNow, "Paused schedules should still allow manual Back Up Now.")
        try require(!paused.canRunDueBackups, "Paused schedules should disable Run Due Backups.")

        let active = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .backup,
            activeStopRequest: nil
        )
        try require(!active.canBackUpNow, "Active jobs should disable Back Up Now.")
        try require(active.canPauseActiveBackup, "Active backups should allow Pause.")
        try require(active.canStopActiveJob, "Active backups should allow Stop.")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        # Delta Installed Menu Bar Surface Acceptance

        - Generated: \(timestamp)
        - App: \(bundle.bundleURL.path)

        This verifies the installed Delta app's status-menu product surface without opening the native popover. It proves menu bar status text, badge text, action availability, compact label length, and forbidden implementation/status terminology through the same shared presentation policy used by the AppKit status item and SwiftUI popover.

        ## Result

        Installed menu bar surface acceptance passed.

        - Ready status: \(ready.headerText) / \(ready.badgeText) / \(ready.symbolName)
        - Running backup status: \(runningBackup.headerText) / \(runningBackup.badgeText) / \(runningBackup.symbolName)
        - Running restore status: \(runningRestore.headerText) / \(runningRestore.badgeText) / \(runningRestore.symbolName)
        - Completed backup status: \(completed.headerText) / \(completed.badgeText) / \(completed.symbolName)
        - Warning backup status: \(warning.headerText) / \(warning.badgeText) / \(warning.symbolName)
        - Failed backup status: \(failed.headerText) / \(failed.badgeText) / \(failed.symbolName)
        - Blocked status: \(blocked.headerText) / \(blocked.badgeText) / \(blocked.symbolName)
        - Required actions: \(MenuBarSurfaceContract.actionTitles.joined(separator: ", "))
        - Pause automatic runs leaves manual backup available: \(paused.canBackUpNow ? "Yes" : "No")
        - Active backup exposes Pause and Stop: \(active.canPauseActiveBackup && active.canStopActiveJob ? "Yes" : "No")
        """
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw AcceptanceMenuBarSurfaceError.validationFailed(message)
        }
    }
}

enum AcceptanceMenuBarSurfaceError: LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
