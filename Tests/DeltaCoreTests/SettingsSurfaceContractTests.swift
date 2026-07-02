import XCTest
@testable import DeltaCore

final class SettingsSurfaceContractTests: XCTestCase {
    func testSettingsSurfaceContractCoversRequiredCategoriesAndSummary() {
        XCTAssertEqual(
            SettingsSurfaceContract.categoryTitles,
            ["General", "Defaults", "Updates", "Advanced"]
        )
        XCTAssertEqual(
            SettingsSurfaceContract.statusSummaryTitles,
            ["System Access", "Schedules", "Passwords", "Updates", "Notifications", "Status Menu", "Backup Tools"]
        )
    }

    func testSettingsSurfaceContractCoversProductionReadinessControls() {
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Background Backup Service"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Background Password Access"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Full Disk Access"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Power & Reliability"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Automatic Updates"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Diagnostics"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Pause scheduled automation"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Backup freshness"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Destination checks"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Activity log detail"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("History retention"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Run Due Now"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Repair Password Access"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Restore Recommended"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Check Now"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Send Test Alert"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Copy Report"))
    }

    func testSettingsSurfaceContractUsesProductLanguage() {
        let visibleText = SettingsSurfaceContract.allVisibleStrings().joined(separator: "\n")

        XCTAssertFalse(visibleText.contains("LaunchAgent"))
        XCTAssertFalse(visibleText.contains("Launch Agent"))
        XCTAssertFalse(visibleText.contains("SMAppServiceStatus"))
        XCTAssertFalse(visibleText.contains("rawValue"))
        XCTAssertTrue(SettingsSurfaceContract.validationFailures().isEmpty)
    }

    func testSettingsSurfaceContractMapsToManualAcceptanceCoverage() {
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Plain-language Background Backup Service status"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Background password access repair"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Compact status summary"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Run Due Now scheduler action"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Sparkle automatic check and download controls"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Idle-sleep protection"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Reset controls for recommended backup and restore defaults"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Backup freshness warning control"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Source access warning visibility through dashboard health"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Destination check warning control"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Activity history retention"))
    }
}
