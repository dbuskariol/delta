import XCTest
@testable import DeltaCore

final class DiagnosticReportTests: XCTestCase {
    func testDiagnosticReportIncludesOperationalStateWithoutBackendSecrets() {
        let snapshot = DiagnosticReportSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "0.1",
            buildVersion: "1",
            bundleIdentifier: "com.delta.backup",
            bundlePath: "/Applications/Delta.app",
            executablePath: "/Applications/Delta.app/Contents/MacOS/Delta",
            applicationSupportPath: "/Users/me/Library/Application Support/Delta",
            databasePath: "/Users/me/Library/Application Support/Delta/Delta.sqlite",
            logPath: "/Users/me/Library/Application Support/Delta/Logs",
            fullDiskAccessStatus: "Ready",
            backgroundBackupsStatus: "Enabled",
            appLoginItemStatus: "Enabled",
            notificationStatus: "Enabled",
            menuBarStatus: "Shown",
            backupFreshnessStatus: "Warn after 3 days",
            destinationVerificationStatus: "Warn after 30 days",
            restoreDefaultsStatus: "Preview first, verify files, Replace changed",
            activeOperation: "Backup: Backing up Mac",
            profileCount: 1,
            destinationCount: 1,
            restorePointCount: 2,
            recentJobCount: 3,
            tools: [
                DiagnosticToolSummary(name: "restic", path: "/Applications/Delta.app/Contents/MacOS/restic", isExecutable: true),
                DiagnosticToolSummary(name: "rclone", path: "/Applications/Delta.app/Contents/MacOS/rclone", isExecutable: false)
            ],
            destinations: [
                DiagnosticDestinationSummary(name: "Primary", kind: "Local or mounted drive", lastVerifiedAt: Date(timeIntervalSince1970: 10))
            ],
            profiles: [
                DiagnosticProfileSummary(name: "Mac", sourceMode: "Custom folders", sourceCount: 2, scheduleEnabled: true, customExcludeCount: 1)
            ],
            recentJobs: [
                DiagnosticJobSummary(kind: "Backup", status: "succeeded", startedAt: Date(timeIntervalSince1970: 20), exitCode: 0, message: "Backup summary")
            ]
        )

        let report = DiagnosticReportBuilder().makeReport(snapshot: snapshot)

        XCTAssertTrue(report.contains("# Delta Diagnostic Report"))
        XCTAssertTrue(report.contains("- Version: 0.1 (1)"))
        XCTAssertTrue(report.contains("- Full Disk Access: Ready"))
        XCTAssertTrue(report.contains("- Background Backups: Enabled"))
        XCTAssertTrue(report.contains("- Start at Login: Enabled"))
        XCTAssertTrue(report.contains("- Notifications: Enabled"))
        XCTAssertTrue(report.contains("- Menu Bar: Shown"))
        XCTAssertTrue(report.contains("- Backup Freshness: Warn after 3 days"))
        XCTAssertTrue(report.contains("- Destination Verification: Warn after 30 days"))
        XCTAssertTrue(report.contains("- Restore Defaults: Preview first, verify files, Replace changed"))
        XCTAssertTrue(report.contains("- restic: executable at /Applications/Delta.app/Contents/MacOS/restic"))
        XCTAssertTrue(report.contains("- rclone: missing at /Applications/Delta.app/Contents/MacOS/rclone"))
        XCTAssertTrue(report.contains("- Primary: Local or mounted drive; verified 1970-01-01T00:00:10Z"))
        XCTAssertTrue(report.contains("- Mac: Custom folders; 2 source(s); scheduled; 1 extra exclude(s)"))
        XCTAssertTrue(report.contains("- 1970-01-01T00:00:20Z: Backup succeeded; exit 0; Backup summary"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(report.contains("AWS_SECRET_ACCESS_KEY"))
    }

    func testDiagnosticReportUsesNoneForEmptyLists() {
        let snapshot = DiagnosticReportSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "0.1",
            buildVersion: "1",
            bundleIdentifier: "com.delta.backup",
            bundlePath: "/Applications/Delta.app",
            executablePath: "/Applications/Delta.app/Contents/MacOS/Delta",
            applicationSupportPath: "/support",
            databasePath: "/support/Delta.sqlite",
            logPath: "/support/Logs",
            fullDiskAccessStatus: "Needs Access",
            backgroundBackupsStatus: "Not Registered",
            appLoginItemStatus: "Not Registered",
            notificationStatus: "Disabled",
            menuBarStatus: "Hidden",
            backupFreshnessStatus: "Warn after 3 days",
            destinationVerificationStatus: "Warn after 30 days",
            restoreDefaultsStatus: "Preview first, verify files, Replace changed",
            activeOperation: nil,
            profileCount: 0,
            destinationCount: 0,
            restorePointCount: 0,
            recentJobCount: 0,
            tools: [],
            destinations: [],
            profiles: [],
            recentJobs: []
        )

        let report = DiagnosticReportBuilder().makeReport(snapshot: snapshot)

        XCTAssertTrue(report.contains("- Active Operation: None"))
        XCTAssertEqual(report.components(separatedBy: "- None").count - 1, 4)
    }
}
