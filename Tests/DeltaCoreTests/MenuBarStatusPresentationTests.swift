import XCTest
@testable import DeltaCore

final class MenuBarStatusPresentationTests: XCTestCase {
    func testUnavailableStoreShowsBlockedState() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: false,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )

        XCTAssertEqual(presentation.symbolName, "externaldrive.badge.exclamationmark")
        XCTAssertEqual(presentation.headerText, "Storage unavailable")
        XCTAssertEqual(presentation.badgeText, "Blocked")
        XCTAssertEqual(presentation.accessibilityLabel, "Delta, storage unavailable")
        XCTAssertEqual(presentation.tone, .blocked)
    }

    func testReadyStateWithoutPreviousBackups() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: nil
        )

        XCTAssertEqual(presentation.symbolName, "externaldrive.badge.checkmark")
        XCTAssertEqual(presentation.headerText, "Ready")
        XCTAssertEqual(presentation.badgeText, "Ready")
        XCTAssertEqual(presentation.accessibilityLabel, "Delta, ready")
        XCTAssertEqual(presentation.tone, .ready)
    }

    func testDestinationAttentionOverridesReadyButNotAnActiveBackupFailure() {
        let readyWithDestinationFailure = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded,
            hasDestinationAttention: true
        )

        XCTAssertEqual(readyWithDestinationFailure.headerText, "Destination needs attention")
        XCTAssertEqual(readyWithDestinationFailure.badgeText, "Attention")
        XCTAssertEqual(readyWithDestinationFailure.tone, .attention)

        let failedBackup = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .failed,
            hasDestinationAttention: true
        )
        XCTAssertEqual(failedBackup.headerText, "Last backup failed")
    }

    func testActiveBackupShowsRunningState() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: true,
            activeJobKind: .backup,
            latestBackupStatus: .failed
        )

        XCTAssertEqual(presentation.symbolName, "arrow.triangle.2.circlepath")
        XCTAssertEqual(presentation.headerText, "Backup running")
        XCTAssertEqual(presentation.badgeText, "Running")
        XCTAssertEqual(presentation.accessibilityLabel, "Delta, backup running")
        XCTAssertEqual(presentation.tone, .running)
    }

    func testActiveRestoreShowsSpecificRunningState() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: true,
            activeJobKind: .restore,
            latestBackupStatus: nil
        )

        XCTAssertEqual(presentation.headerText, "Restore running")
        XCTAssertEqual(presentation.accessibilityLabel, "Delta, restore running")
    }

    func testSuccessfulBackupReturnsReadyStateWithLastBackupContext() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )

        XCTAssertEqual(presentation.symbolName, "externaldrive.badge.checkmark")
        XCTAssertEqual(presentation.headerText, "Last backup completed")
        XCTAssertEqual(presentation.badgeText, "Ready")
        XCTAssertEqual(presentation.accessibilityLabel, "Delta, last backup Completed")
        XCTAssertEqual(presentation.tone, .ready)
    }

    func testAttentionBackupStatesUseWarningSymbolAndStatusBadge() {
        for status in [JobStatus.failed, .warning, .cancelled] {
            let presentation = MenuBarStatusPresentation.make(
                isPersistentStoreAvailable: true,
                isWorking: false,
                activeJobKind: nil,
                latestBackupStatus: status
            )

            XCTAssertEqual(presentation.symbolName, "externaldrive.badge.exclamationmark")
            XCTAssertEqual(presentation.headerText, "Last backup \(status.displayName.lowercased())")
            XCTAssertEqual(presentation.badgeText, status.displayName)
            XCTAssertEqual(presentation.accessibilityLabel, "Delta, last backup \(status.displayName)")
            XCTAssertEqual(presentation.tone, .attention)
        }
    }

    func testAcknowledgedOmissionsReturnMenuBarToReady() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .warning,
            acknowledgedOmissionCount: 6
        )

        XCTAssertEqual(presentation.symbolName, "externaldrive.badge.checkmark")
        XCTAssertEqual(presentation.headerText, "Last backup completed")
        XCTAssertEqual(presentation.badgeText, "Ready")
        XCTAssertEqual(presentation.tone, .ready)
        XCTAssertTrue(presentation.accessibilityLabel.contains("6 known omissions"))
    }
}
