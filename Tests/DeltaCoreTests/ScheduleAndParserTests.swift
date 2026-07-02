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

    private func components(_ calendar: Calendar, year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))!
    }
}
