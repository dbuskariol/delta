import XCTest
@testable import DeltaCore

final class SettingsSurfaceContractTests: XCTestCase {
    func testSettingsSurfaceContractCoversRequiredCategoriesAndSummary() {
        XCTAssertEqual(
            SettingsSurfaceContract.categoryTitles,
            ["General", "Permissions", "Defaults", "Updates", "Advanced"]
        )
        XCTAssertEqual(
            SettingsSurfaceContract.statusSummaryTitles,
            ["System Access", "Schedules", "Passwords", "Updates", "Notifications", "Status Menu", "Backup Tools"]
        )
    }

    func testSettingsSurfaceContractCoversProductionReadinessControls() {
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Scheduled Backups"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("System Access"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Power & Reliability"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Automatic Updates"))
        XCTAssertTrue(SettingsSurfaceContract.cardTitles.contains("Diagnostics"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Allow scheduled backups"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Pause automatic runs"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Backup freshness"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Destination checks"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Destination free space"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Schedule new profiles"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("Default schedule"))
        XCTAssertTrue(SettingsSurfaceContract.controlTitles.contains("History retention"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Run Due Now"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Open Activity"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("How Scheduled Backups Work"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Repair Password Access"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Restore Recommended"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Check Now"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Send Test Alert"))
        XCTAssertTrue(SettingsSurfaceContract.actionTitles.contains("Copy Report"))
        XCTAssertTrue(SettingsSurfaceContract.capabilityTitles.contains("Approved by macOS"))
    }

    func testSettingsSurfaceContractUsesProductLanguage() {
        let visibleText = SettingsSurfaceContract.allVisibleStrings().joined(separator: "\n")

        for term in SettingsSurfaceContract.forbiddenVisibleTerms {
            XCTAssertFalse(
                visibleText.localizedCaseInsensitiveContains(term),
                "Settings visible text exposes implementation/control term: \(term)"
            )
        }
        XCTAssertTrue(SettingsSurfaceContract.validationFailures().isEmpty)
    }

    func testSettingsSurfaceContractMapsToManualAcceptanceCoverage() {
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Plain-language Scheduled Backups status"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Plain-language scheduled backup explanation"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("No raw system service terminology"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Scheduled Backups activity shortcut"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Password access repair"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Compact status summary"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Run Due Now scheduled-backup action"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Expandable Scheduled Backups explanation"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Sparkle automatic check and download controls"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Idle-sleep protection"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Reset controls for recommended backup and restore defaults"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Configurable new-profile schedule defaults"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Backup freshness warning control"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Source access warning visibility through dashboard health"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Destination check warning control"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Destination free-space warning control"))
        XCTAssertTrue(SettingsSurfaceContract.requiredManualAcceptanceCoverage.contains("Activity history retention"))
    }
}
