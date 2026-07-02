import XCTest
@testable import DeltaCore

final class MenuBarActionAvailabilityTests: XCTestCase {
    func testReadyWithProfilesEnablesManualAndDueBackupActions() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 2,
            isPersistentStoreAvailable: true,
            isWorking: false,
            pausesScheduledBackups: false,
            activeJobKind: nil,
            activeStopRequest: nil
        )

        XCTAssertTrue(availability.canBackUpNow)
        XCTAssertTrue(availability.canRunDueBackups)
        XCTAssertFalse(availability.canPauseActiveBackup)
        XCTAssertFalse(availability.canStopActiveJob)
        XCTAssertEqual(availability.runDueTitle, "Run Due Backups")
        XCTAssertEqual(availability.runDueSymbolName, "calendar.badge.clock")
    }

    func testMissingProfilesDisablesBackupActions() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 0,
            isPersistentStoreAvailable: true,
            isWorking: false,
            pausesScheduledBackups: false,
            activeJobKind: nil,
            activeStopRequest: nil
        )

        XCTAssertFalse(availability.canBackUpNow)
        XCTAssertFalse(availability.canRunDueBackups)
    }

    func testPausedSchedulesDisableOnlyRunDueBackups() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: false,
            pausesScheduledBackups: true,
            activeJobKind: nil,
            activeStopRequest: nil
        )

        XCTAssertTrue(availability.canBackUpNow)
        XCTAssertFalse(availability.canRunDueBackups)
        XCTAssertEqual(availability.runDueTitle, "Scheduled Paused")
        XCTAssertEqual(availability.runDueSymbolName, "pause.circle")
        XCTAssertEqual(
            availability.runDueTooltip,
            "Scheduled backups are paused in Settings. Manual Back Up Now is still available."
        )
    }

    func testUnavailableStoreDisablesWorkStartingAndStopActions() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: false,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .backup,
            activeStopRequest: nil
        )

        XCTAssertFalse(availability.canBackUpNow)
        XCTAssertFalse(availability.canRunDueBackups)
        XCTAssertFalse(availability.canPauseActiveBackup)
        XCTAssertFalse(availability.canStopActiveJob)
    }

    func testActiveBackupEnablesPauseAndStopButNotNewRuns() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .backup,
            activeStopRequest: nil
        )

        XCTAssertFalse(availability.canBackUpNow)
        XCTAssertFalse(availability.canRunDueBackups)
        XCTAssertTrue(availability.canPauseActiveBackup)
        XCTAssertTrue(availability.canStopActiveJob)
    }

    func testActiveRestoreEnablesStopButNotPause() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .restore,
            activeStopRequest: nil
        )

        XCTAssertFalse(availability.canPauseActiveBackup)
        XCTAssertTrue(availability.canStopActiveJob)
    }

    func testPendingStopRequestDisablesRepeatedStopActions() {
        let availability = MenuBarActionAvailability.make(
            profileCount: 1,
            isPersistentStoreAvailable: true,
            isWorking: true,
            pausesScheduledBackups: false,
            activeJobKind: .backup,
            activeStopRequest: .pause
        )

        XCTAssertFalse(availability.canPauseActiveBackup)
        XCTAssertFalse(availability.canStopActiveJob)
    }
}
