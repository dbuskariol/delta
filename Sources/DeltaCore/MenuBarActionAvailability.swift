import Foundation

public struct MenuBarActionAvailability: Equatable, Sendable {
    public var canBackUpNow: Bool
    public var canRunDueBackups: Bool
    public var canPauseActiveBackup: Bool
    public var canStopActiveJob: Bool
    public var runDueTitle: String
    public var runDueSymbolName: String
    public var runDueTooltip: String

    public init(
        canBackUpNow: Bool,
        canRunDueBackups: Bool,
        canPauseActiveBackup: Bool,
        canStopActiveJob: Bool,
        runDueTitle: String,
        runDueSymbolName: String,
        runDueTooltip: String
    ) {
        self.canBackUpNow = canBackUpNow
        self.canRunDueBackups = canRunDueBackups
        self.canPauseActiveBackup = canPauseActiveBackup
        self.canStopActiveJob = canStopActiveJob
        self.runDueTitle = runDueTitle
        self.runDueSymbolName = runDueSymbolName
        self.runDueTooltip = runDueTooltip
    }

    public static func make(
        profileCount: Int,
        isPersistentStoreAvailable: Bool,
        isWorking: Bool,
        pausesScheduledBackups: Bool,
        activeJobKind: JobKind?,
        activeStopRequest: ResticRunStopReason?
    ) -> MenuBarActionAvailability {
        let hasProfiles = profileCount > 0
        let noStopPending = activeStopRequest == nil
        return MenuBarActionAvailability(
            canBackUpNow: hasProfiles && !isWorking && isPersistentStoreAvailable,
            canRunDueBackups: hasProfiles && !isWorking && !pausesScheduledBackups && isPersistentStoreAvailable,
            canPauseActiveBackup: isPersistentStoreAvailable
                && isWorking
                && activeJobKind == .backup
                && noStopPending,
            canStopActiveJob: isPersistentStoreAvailable
                && isWorking
                && activeJobKind != nil
                && noStopPending,
            runDueTitle: pausesScheduledBackups ? "Scheduled Paused" : "Run Due Backups",
            runDueSymbolName: pausesScheduledBackups ? "pause.circle" : "calendar.badge.clock",
            runDueTooltip: pausesScheduledBackups
                ? "Scheduled backups are paused in Settings. Manual Back Up Now is still available."
                : "Run every backup profile that is currently due."
        )
    }
}
