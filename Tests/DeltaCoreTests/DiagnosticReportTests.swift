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
            backgroundBackupsStatus: "Ready",
            appLoginItemStatus: "Ready",
            notificationStatus: "Enabled",
            menuBarStatus: "Shown",
            idleSleepProtectionStatus: "Enabled",
            operationalHistoryRetentionStatus: "Keep 90 days",
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
        XCTAssertTrue(report.contains("- Background Backups: Ready"))
        XCTAssertTrue(report.contains("- Start at Login: Ready"))
        XCTAssertTrue(report.contains("- Notifications: Enabled"))
        XCTAssertTrue(report.contains("- Menu Bar: Shown"))
        XCTAssertTrue(report.contains("- Idle Sleep Protection: Enabled"))
        XCTAssertTrue(report.contains("- Activity History Retention: Keep 90 days"))
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
            backgroundBackupsStatus: "Off",
            appLoginItemStatus: "Off",
            notificationStatus: "Disabled",
            menuBarStatus: "Hidden",
            idleSleepProtectionStatus: "Disabled",
            operationalHistoryRetentionStatus: "Keep 90 days",
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

    func testDiagnosticReportRedactsSecretsFromUserVisibleFieldsAndJobMessages() {
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
            fullDiskAccessStatus: "Ready",
            backgroundBackupsStatus: "Ready",
            appLoginItemStatus: "Ready",
            notificationStatus: "Disabled",
            menuBarStatus: "Shown",
            idleSleepProtectionStatus: "Enabled",
            operationalHistoryRetentionStatus: "Keep 90 days",
            backupFreshnessStatus: "Warn after 3 days",
            destinationVerificationStatus: "Warn after 30 days",
            restoreDefaultsStatus: "Preview first, verify files, Replace changed",
            activeOperation: "Backup: rest:https://user:super-secret@example.com/repo",
            profileCount: 1,
            destinationCount: 1,
            restorePointCount: 0,
            recentJobCount: 1,
            tools: [],
            destinations: [
                DiagnosticDestinationSummary(name: "Primary rest:https://user:super-secret@example.com/repo", kind: "S3-compatible")
            ],
            profiles: [
                DiagnosticProfileSummary(
                    name: "Mac AWS_SECRET_ACCESS_KEY=super-secret",
                    sourceMode: "Custom folders",
                    sourceCount: 1,
                    scheduleEnabled: true,
                    customExcludeCount: 0
                )
            ],
            recentJobs: [
                DiagnosticJobSummary(
                    kind: "Backup",
                    status: "Failed",
                    startedAt: Date(timeIntervalSince1970: 20),
                    exitCode: 1,
                    message: "Failed for rest:https://user:super-secret@example.com/repo with AWS_SECRET_ACCESS_KEY=super-secret"
                )
            ]
        )

        let report = DiagnosticReportBuilder().makeReport(snapshot: snapshot)

        XCTAssertFalse(report.contains("super-secret"))
        XCTAssertTrue(report.contains("rest:https://<redacted>@example.com/repo"))
        XCTAssertTrue(report.contains("AWS_SECRET_ACCESS_KEY=<redacted>"))
    }

    func testDiagnosticReportSummarizesRawResticJSONJobMessages() {
        let rawResticOutput = """
        {"message_type":"status","seconds_elapsed":1,"percent_done":0.5,"total_files":10,"files_done":5,"total_bytes":1000,"bytes_done":500}
        {"message_type":"summary","files_new":0,"files_changed":0,"files_unmodified":10,"data_added":0,"total_files_processed":10,"total_bytes_processed":1000}
        """
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
            fullDiskAccessStatus: "Ready",
            backgroundBackupsStatus: "Ready",
            appLoginItemStatus: "Ready",
            notificationStatus: "Disabled",
            menuBarStatus: "Shown",
            idleSleepProtectionStatus: "Enabled",
            operationalHistoryRetentionStatus: "Keep 90 days",
            backupFreshnessStatus: "Warn after 3 days",
            destinationVerificationStatus: "Warn after 30 days",
            restoreDefaultsStatus: "Preview first, verify files, Replace changed",
            activeOperation: nil,
            profileCount: 0,
            destinationCount: 0,
            restorePointCount: 0,
            recentJobCount: 1,
            tools: [],
            destinations: [],
            profiles: [],
            recentJobs: [
                DiagnosticJobSummary(
                    kind: "Backup",
                    status: "Completed",
                    startedAt: Date(timeIntervalSince1970: 20),
                    exitCode: 0,
                    message: rawResticOutput
                )
            ]
        )

        let report = DiagnosticReportBuilder().makeReport(snapshot: snapshot)

        XCTAssertTrue(report.contains("No changes detected"))
        XCTAssertFalse(report.contains(#""message_type":"status""#))
        XCTAssertFalse(report.contains(#""message_type":"summary""#))
    }

    func testDiagnosticReportFormatsResticInitializedEvent() {
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
            fullDiskAccessStatus: "Ready",
            backgroundBackupsStatus: "Ready",
            appLoginItemStatus: "Ready",
            notificationStatus: "Disabled",
            menuBarStatus: "Shown",
            idleSleepProtectionStatus: "Enabled",
            operationalHistoryRetentionStatus: "Keep 90 days",
            backupFreshnessStatus: "Warn after 3 days",
            destinationVerificationStatus: "Warn after 30 days",
            restoreDefaultsStatus: "Preview first, verify files, Replace changed",
            activeOperation: nil,
            profileCount: 0,
            destinationCount: 0,
            restorePointCount: 0,
            recentJobCount: 1,
            tools: [],
            destinations: [],
            profiles: [],
            recentJobs: [
                DiagnosticJobSummary(
                    kind: "Prepare destination",
                    status: "Completed",
                    startedAt: Date(timeIntervalSince1970: 20),
                    exitCode: 0,
                    message: #"{"message_type":"initialized","id":"abc","repository":"/Volumes/SSD/Delta"}"#
                )
            ]
        )

        let report = DiagnosticReportBuilder().makeReport(snapshot: snapshot)

        XCTAssertTrue(report.contains("Destination prepared"))
        XCTAssertFalse(report.contains(#""message_type":"initialized""#))
    }

    func testDiagnosticSnapshotCollectorReadsDatabaseState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repositoryID = UUID()
        let profileID = UUID()
        let repository = BackupRepository(
            id: repositoryID,
            name: "Primary",
            backend: .local(path: "/tmp/delta"),
            lastVerifiedAt: Date(timeIntervalSince1970: 10)
        )
        let profile = BackupProfile(
            id: profileID,
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/tmp/source")],
            repositoryID: repositoryID,
            schedule: BackupSchedule(isEnabled: true)
        )
        let job = JobRun(
            profileID: profileID,
            repositoryID: repositoryID,
            kind: .backup,
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 20),
            exitCode: 0,
            message: "Backup completed"
        )
        let snapshot = ResticSnapshot(
            id: "snapshot",
            time: Date(timeIntervalSince1970: 30),
            paths: ["/tmp/source"]
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)
        try database.saveJobRun(job)
        try database.saveSnapshot(snapshot, repositoryID: repositoryID)

        let reportSnapshot = DiagnosticSnapshotCollector(
            database: database,
            bundle: Bundle(for: Self.self)
        ).snapshot(activeOperation: "Backup: Mac")

        XCTAssertEqual(reportSnapshot.profileCount, 1)
        XCTAssertEqual(reportSnapshot.destinationCount, 1)
        XCTAssertEqual(reportSnapshot.restorePointCount, 1)
        XCTAssertEqual(reportSnapshot.recentJobCount, 1)
        XCTAssertEqual(reportSnapshot.destinations.first?.name, "Primary")
        XCTAssertEqual(reportSnapshot.profiles.first?.name, "Mac")
        XCTAssertEqual(reportSnapshot.recentJobs.first?.message, "Backup completed")
        XCTAssertEqual(reportSnapshot.activeOperation, "Backup: Mac")
    }
}
