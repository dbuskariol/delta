import XCTest
@testable import DeltaCore

final class ScheduleAndParserTests: XCTestCase {
    func testDailyScheduleIsDueAfterNextRun() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let lastRun = components(calendar, year: 2026, month: 7, day: 1, hour: 20, minute: 0)
        let now = components(calendar, year: 2026, month: 7, day: 2, hour: 20, minute: 1)
        let decision = evaluator.decision(for: BackupSchedule(kind: .daily(hour: 20, minute: 0)), lastRun: lastRun, now: now)

        XCTAssertTrue(decision.isDue)
    }

    func testScheduleWithoutCatchUpRunsInsideGraceWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar, missedRunGraceInterval: 15 * 60)
        let lastRun = components(calendar, year: 2026, month: 7, day: 1, hour: 20, minute: 0)
        let now = components(calendar, year: 2026, month: 7, day: 2, hour: 20, minute: 5)
        let schedule = BackupSchedule(kind: .daily(hour: 20, minute: 0), catchUpMissedRuns: false)

        let decision = evaluator.decision(for: schedule, lastRun: lastRun, now: now)

        XCTAssertTrue(decision.isDue)
    }

    func testScheduleWithoutCatchUpSkipsStaleMissedRun() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar, missedRunGraceInterval: 15 * 60)
        let lastRun = components(calendar, year: 2026, month: 7, day: 1, hour: 20, minute: 0)
        let now = components(calendar, year: 2026, month: 7, day: 3, hour: 9, minute: 0)
        let schedule = BackupSchedule(kind: .daily(hour: 20, minute: 0), catchUpMissedRuns: false)

        let decision = evaluator.decision(for: schedule, lastRun: lastRun, now: now)

        XCTAssertFalse(decision.isDue)
        XCTAssertEqual(decision.nextRun, components(calendar, year: 2026, month: 7, day: 3, hour: 20, minute: 0))
    }

    func testMonthlyScheduleClampsToLastDayOfShortMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let date = components(calendar, year: 2026, month: 2, day: 1, hour: 12, minute: 0)
        let next = evaluator.nextRun(after: date, kind: .monthly(day: 31, hour: 9, minute: 30))
        let day = calendar.component(.day, from: next!)

        XCTAssertEqual(day, 28)
    }

    func testMaintenanceScheduleRunsAtFirstWindowAfterProfileCreation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let createdAt = components(calendar, year: 2026, month: 7, day: 1, hour: 1, minute: 0)
        let now = components(calendar, year: 2026, month: 7, day: 1, hour: 2, minute: 1)
        let schedule = RetentionMaintenanceSchedule(intervalDays: 7, hour: 2, minute: 0)

        let decision = evaluator.maintenanceDecision(for: schedule, profileCreatedAt: createdAt, lastMaintenanceRun: nil, now: now)

        XCTAssertTrue(decision.isDue)
        XCTAssertEqual(decision.nextRun, components(calendar, year: 2026, month: 7, day: 1, hour: 2, minute: 0))
    }

    func testMaintenanceScheduleUsesIntervalAfterLastCleanup() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let createdAt = components(calendar, year: 2026, month: 7, day: 1, hour: 1, minute: 0)
        let lastCleanup = components(calendar, year: 2026, month: 7, day: 1, hour: 2, minute: 3)
        let beforeNextWindow = components(calendar, year: 2026, month: 7, day: 8, hour: 1, minute: 59)
        let afterNextWindow = components(calendar, year: 2026, month: 7, day: 8, hour: 2, minute: 1)
        let schedule = RetentionMaintenanceSchedule(intervalDays: 7, hour: 2, minute: 0)

        let earlyDecision = evaluator.maintenanceDecision(for: schedule, profileCreatedAt: createdAt, lastMaintenanceRun: lastCleanup, now: beforeNextWindow)
        let dueDecision = evaluator.maintenanceDecision(for: schedule, profileCreatedAt: createdAt, lastMaintenanceRun: lastCleanup, now: afterNextWindow)

        XCTAssertFalse(earlyDecision.isDue)
        XCTAssertTrue(dueDecision.isDue)
        XCTAssertEqual(dueDecision.nextRun, components(calendar, year: 2026, month: 7, day: 8, hour: 2, minute: 0))
    }

    func testSnapshotParserDecodesResticJSON() throws {
        let json = """
        [
          {
            "time": "2026-07-02T08:30:00.123456789+10:00",
            "tree": "tree-id",
            "paths": ["/Users/me/Documents"],
            "hostname": "mac",
            "username": "me",
            "id": "snapshot-id",
            "tags": ["delta"]
          }
        ]
        """

        let snapshots = try ResticJSONParser().parseSnapshots(from: json)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].id, "snapshot-id")
        XCTAssertEqual(snapshots[0].paths, ["/Users/me/Documents"])
        XCTAssertEqual(snapshots[0].tags, ["delta"])
    }

    func testSnapshotEntryParserDecodesResticLsJSONLines() throws {
        let jsonLines = """
        {"time":"2026-07-02T08:30:00.123456789+10:00","paths":["/Users/me/Documents"],"id":"snapshot-id","message_type":"snapshot","struct_type":"snapshot"}
        {"name":"Documents","type":"dir","path":"/Users/me/Documents","mtime":"2026-07-02T08:30:00.123456789+10:00","message_type":"node","struct_type":"node"}
        {"name":"Budget.numbers","type":"file","path":"/Users/me/Documents/Budget.numbers","size":2048,"mtime":"2026-07-02T08:31:00+10:00","message_type":"node","struct_type":"node"}
        """

        let entries = try ResticJSONParser().parseSnapshotEntries(from: jsonLines)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "/Users/me/Documents")
        XCTAssertEqual(entries[0].type, .directory)
        XCTAssertEqual(entries[1].name, "Budget.numbers")
        XCTAssertEqual(entries[1].size, 2048)
        XCTAssertEqual(entries[1].type, .file)
        XCTAssertNotNil(entries[1].modifiedAt)
    }

    func testLaunchAgentStatusParserHandlesKnownServiceManagementStates() {
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("enabled"), .enabled)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("requiresApproval"), .requiresApproval)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("notRegistered"), .notRegistered)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("notFound"), .notFound)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("unavailable"), .unavailable)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("futureState"), .unknown("futureState"))
    }

    func testLaunchAgentStatusDisplayNamesUseProductLanguage() {
        XCTAssertEqual(LaunchAgentRegistrationStatus.enabled.displayName, "Ready")
        XCTAssertEqual(LaunchAgentRegistrationStatus.requiresApproval.displayName, "Needs Approval")
        XCTAssertEqual(LaunchAgentRegistrationStatus.notRegistered.displayName, "Off")
        XCTAssertEqual(LaunchAgentRegistrationStatus.notFound.displayName, "Missing Scheduler")
    }

    func testLaunchAgentStatusParserHandlesRawServiceManagementStates() {
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("SMAppServiceStatus(rawValue: 0)"), .notRegistered)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("SMAppServiceStatus(rawValue: 1)"), .enabled)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("SMAppServiceStatus(rawValue: 2)"), .requiresApproval)
        XCTAssertEqual(LaunchAgentRegistrationStatus.parse("SMAppServiceStatus(rawValue: 3)"), .notFound)
    }

    func testUnknownLaunchAgentStatusDoesNotExposeRawServiceManagementText() {
        let status = LaunchAgentRegistrationStatus.parse("SMAppServiceStatus(rawValue: 99)")

        XCTAssertEqual(status.displayName, "Unknown")
        XCTAssertEqual(status.detail, "macOS returned an unknown schedule status.")
    }

    func testBackgroundBackupPresentationTreatsUnscheduledUnregisteredServiceAsNotNeeded() {
        let presentation = BackgroundBackupServicePresentation.make(
            status: .notRegistered,
            scheduledProfileCount: 0,
            pausesScheduledBackups: false
        )

        XCTAssertEqual(presentation.statusText, "Not Needed")
        XCTAssertEqual(presentation.statusDetail, "No scheduled profiles")
        XCTAssertEqual(presentation.approvalText, "Off")
        XCTAssertEqual(presentation.severity, .inactive)
        XCTAssertFalse(presentation.needsAttention)
    }

    func testBackgroundBackupPurposeUsesProductLanguage() {
        let text = BackgroundBackupServicePresentation.purposeText

        XCTAssertTrue(text.contains("Scheduled Backups"))
        XCTAssertTrue(text.contains("signed macOS Login Item scheduler"))
        for forbiddenTerm in ["LaunchAgent", "Launch Agent", "SMAppService", "rawValue", "Register", "Unregister"] {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(forbiddenTerm),
                "Scheduled backup explanation exposes implementation term: \(forbiddenTerm)"
            )
        }
    }

    func testBackgroundBackupPresentationSurfacesReadyScheduledService() {
        let presentation = BackgroundBackupServicePresentation.make(
            status: .enabled,
            scheduledProfileCount: 2,
            pausesScheduledBackups: false
        )

        XCTAssertEqual(presentation.statusText, "Ready")
        XCTAssertEqual(presentation.statusDetail, "Schedules can run when closed")
        XCTAssertEqual(presentation.approvalText, "Approved")
        XCTAssertEqual(presentation.severity, .ready)
        XCTAssertFalse(presentation.needsAttention)
        XCTAssertTrue(presentation.controlDetail.contains("2 scheduled profiles"))
    }

    func testBackgroundBackupPresentationShowsApprovalAsActionRequired() {
        let presentation = BackgroundBackupServicePresentation.make(
            status: .requiresApproval,
            scheduledProfileCount: 1,
            pausesScheduledBackups: false
        )

        XCTAssertEqual(presentation.statusText, "Needs Approval")
        XCTAssertEqual(presentation.approvalText, "Needed")
        XCTAssertEqual(presentation.attentionTitle, "macOS approval required")
        XCTAssertEqual(
            presentation.attentionText,
            "Approve Delta in Login Items before scheduled backups can run while the main window is closed."
        )
        XCTAssertEqual(presentation.severity, .attention)
    }

    func testBackgroundBackupPresentationShowsPausedSchedulesWithoutRemovingApproval() {
        let presentation = BackgroundBackupServicePresentation.make(
            status: .enabled,
            scheduledProfileCount: 1,
            pausesScheduledBackups: true
        )

        XCTAssertEqual(presentation.statusText, "Paused")
        XCTAssertEqual(presentation.statusDetail, "Automated runs paused")
        XCTAssertEqual(presentation.approvalText, "Approved")
        XCTAssertEqual(presentation.attentionTitle, "Scheduled backups paused")
        XCTAssertEqual(presentation.severity, .attention)
        XCTAssertTrue(presentation.controlDetail.contains("Keep macOS approval in place"))
    }

    func testBackgroundBackupPresentationUsesProductLanguageForMissingService() {
        let presentation = BackgroundBackupServicePresentation.make(
            status: .notFound,
            scheduledProfileCount: 1,
            pausesScheduledBackups: false
        )

        XCTAssertEqual(presentation.statusText, "Missing Scheduler")
        XCTAssertEqual(presentation.attentionTitle, "Scheduler missing")
        XCTAssertEqual(
            presentation.attentionText,
            "Delta's signed scheduler is missing from the installed app bundle. Reinstall Delta from the latest build."
        )
        XCTAssertEqual(presentation.severity, .blocked)
    }

    private func components(_ calendar: Calendar, year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))!
    }
}
