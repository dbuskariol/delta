import XCTest
@testable import DeltaCore

final class MenuBarSurfaceContractTests: XCTestCase {
    func testMenuBarSurfaceContractCoversRequiredActionsAndStatuses() {
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Back Up Now"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Run Due Backups"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Scheduled Paused"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Pause"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Stop"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Activity"))
        XCTAssertTrue(MenuBarSurfaceContract.actionTitles.contains("Updates"))
        XCTAssertTrue(MenuBarSurfaceContract.statusTexts.contains("Last backup completed"))
        XCTAssertTrue(MenuBarSurfaceContract.statusTexts.contains("Last backup completed with warnings"))
    }

    func testMenuBarSurfaceContractUsesProductLanguage() {
        let visibleText = MenuBarSurfaceContract.allVisibleStrings().joined(separator: "\n")

        for term in MenuBarSurfaceContract.forbiddenVisibleTerms {
            XCTAssertFalse(
                visibleText.localizedCaseInsensitiveContains(term),
                "Menu bar visible text exposes implementation or awkward status term: \(term)"
            )
        }

        XCTAssertTrue(MenuBarSurfaceContract.validationFailures().isEmpty)
    }

    func testSuccessfulBackupDoesNotExposeSucceededInMenuBarStatus() {
        let presentation = MenuBarStatusPresentation.make(
            isPersistentStoreAvailable: true,
            isWorking: false,
            activeJobKind: nil,
            latestBackupStatus: .succeeded
        )

        XCTAssertEqual(presentation.headerText, "Last backup completed")
        XCTAssertEqual(presentation.badgeText, "Ready")
        XCTAssertFalse(presentation.headerText.localizedCaseInsensitiveContains("succeeded"))
        XCTAssertFalse(presentation.badgeText.localizedCaseInsensitiveContains("succeeded"))
    }
}
