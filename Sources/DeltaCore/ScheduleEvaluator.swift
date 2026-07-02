import Foundation

public struct ScheduleDecision: Equatable, Sendable {
    public var isDue: Bool
    public var nextRun: Date?

    public init(isDue: Bool, nextRun: Date?) {
        self.isDue = isDue
        self.nextRun = nextRun
    }
}

public struct ScheduleEvaluator: Sendable {
    public var calendar: Calendar
    public var missedRunGraceInterval: TimeInterval

    public init(calendar: Calendar = .current, missedRunGraceInterval: TimeInterval = 15 * 60) {
        self.calendar = calendar
        self.missedRunGraceInterval = missedRunGraceInterval
    }

    public func decision(for schedule: BackupSchedule, lastRun: Date?, now: Date = Date()) -> ScheduleDecision {
        guard schedule.isEnabled else {
            return ScheduleDecision(isDue: false, nextRun: nil)
        }

        guard let lastRun else {
            return ScheduleDecision(isDue: true, nextRun: nextRun(after: now, kind: schedule.kind))
        }

        guard let latestDueRun = latestScheduledRun(after: lastRun, onOrBefore: now, kind: schedule.kind) else {
            return ScheduleDecision(isDue: false, nextRun: nextRun(after: lastRun, kind: schedule.kind))
        }

        if schedule.catchUpMissedRuns {
            return ScheduleDecision(isDue: true, nextRun: nextRun(after: now, kind: schedule.kind))
        }

        let isInsideGraceWindow = now.timeIntervalSince(latestDueRun) <= missedRunGraceInterval
        return ScheduleDecision(
            isDue: isInsideGraceWindow,
            nextRun: isInsideGraceWindow ? nextRun(after: now, kind: schedule.kind) : nextRun(after: now, kind: schedule.kind)
        )
    }

    public func maintenanceDecision(
        for schedule: RetentionMaintenanceSchedule,
        profileCreatedAt: Date,
        lastMaintenanceRun: Date?,
        now: Date = Date()
    ) -> ScheduleDecision {
        guard schedule.isEnabled else {
            return ScheduleDecision(isDue: false, nextRun: nil)
        }

        let nextRun: Date?
        if let lastMaintenanceRun {
            let lastScheduledWindow = maintenanceWindow(onOrBefore: lastMaintenanceRun, schedule: schedule) ?? lastMaintenanceRun
            let earliestDate = calendar.date(
                byAdding: .day,
                value: max(1, schedule.intervalDays),
                to: lastScheduledWindow
            ) ?? lastScheduledWindow.addingTimeInterval(TimeInterval(max(1, schedule.intervalDays)) * 86_400)
            nextRun = nextMaintenanceRun(onOrAfter: earliestDate, schedule: schedule)
        } else {
            nextRun = nextMaintenanceRun(onOrAfter: profileCreatedAt, schedule: schedule)
        }

        guard let nextRun else {
            return ScheduleDecision(isDue: false, nextRun: nil)
        }
        return ScheduleDecision(isDue: now >= nextRun, nextRun: nextRun)
    }

    public func nextRun(after date: Date, kind: ScheduleKind) -> Date? {
        switch kind {
        case let .hourly(minute):
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            components.minute = clamped(minute, lower: 0, upper: 59)
            components.second = 0
            let candidate = calendar.date(from: components)
            if let candidate, candidate > date {
                return candidate
            }
            return calendar.date(byAdding: .hour, value: 1, to: candidate ?? date)

        case let .daily(hour, minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: clamped(hour, lower: 0, upper: 23), minute: clamped(minute, lower: 0, upper: 59), second: 0),
                matchingPolicy: .nextTime
            )

        case let .weekly(weekday, hour, minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(
                    hour: clamped(hour, lower: 0, upper: 23),
                    minute: clamped(minute, lower: 0, upper: 59),
                    second: 0,
                    weekday: clamped(weekday, lower: 1, upper: 7)
                ),
                matchingPolicy: .nextTime
            )

        case let .monthly(day, hour, minute):
            return nextMonthlyRun(
                after: date,
                day: clamped(day, lower: 1, upper: 31),
                hour: clamped(hour, lower: 0, upper: 23),
                minute: clamped(minute, lower: 0, upper: 59)
            )

        case let .customInterval(seconds):
            return calendar.date(byAdding: .second, value: max(60, Int(seconds)), to: date)
        }
    }

    private func nextMonthlyRun(after date: Date, day: Int, hour: Int, minute: Int) -> Date? {
        var cursor = date
        for _ in 0..<24 {
            let components = calendar.dateComponents([.year, .month], from: cursor)
            guard
                let year = components.year,
                let month = components.month,
                let range = calendar.range(of: .day, in: .month, for: cursor)
            else {
                return nil
            }

            let candidateDay = min(day, range.upperBound - 1)
            let candidate = calendar.date(from: DateComponents(year: year, month: month, day: candidateDay, hour: hour, minute: minute, second: 0))
            if let candidate, candidate > date {
                return candidate
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) else {
                return nil
            }
            cursor = nextMonth
        }
        return nil
    }

    private func nextMaintenanceRun(onOrAfter date: Date, schedule: RetentionMaintenanceSchedule) -> Date? {
        let hour = clamped(schedule.hour, lower: 0, upper: 23)
        let minute = clamped(schedule.minute, lower: 0, upper: 59)
        let startOfDay = calendar.startOfDay(for: date)
        var components = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        components.hour = hour
        components.minute = minute
        components.second = 0

        if let sameDay = calendar.date(from: components), sameDay >= date {
            return sameDay
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return nil
        }
        var nextComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
        nextComponents.hour = hour
        nextComponents.minute = minute
        nextComponents.second = 0
        return calendar.date(from: nextComponents)
    }

    private func maintenanceWindow(onOrBefore date: Date, schedule: RetentionMaintenanceSchedule) -> Date? {
        let hour = clamped(schedule.hour, lower: 0, upper: 23)
        let minute = clamped(schedule.minute, lower: 0, upper: 59)
        let startOfDay = calendar.startOfDay(for: date)
        var components = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        components.hour = hour
        components.minute = minute
        components.second = 0

        if let sameDay = calendar.date(from: components), sameDay <= date {
            return sameDay
        }
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: startOfDay) else {
            return nil
        }
        var previousComponents = calendar.dateComponents([.year, .month, .day], from: previousDay)
        previousComponents.hour = hour
        previousComponents.minute = minute
        previousComponents.second = 0
        return calendar.date(from: previousComponents)
    }

    private func latestScheduledRun(after lastRun: Date, onOrBefore now: Date, kind: ScheduleKind) -> Date? {
        guard now >= lastRun else {
            return nil
        }

        if case let .customInterval(seconds) = kind {
            let interval = max(60, seconds)
            let elapsed = now.timeIntervalSince(lastRun)
            let intervals = floor(elapsed / interval)
            guard intervals >= 1 else {
                return nil
            }
            return lastRun.addingTimeInterval(intervals * interval)
        }

        var cursor = lastRun
        var latest: Date?
        for _ in 0..<10_000 {
            guard let next = nextRun(after: cursor, kind: kind) else {
                return latest
            }
            if next > now {
                return latest
            }
            latest = next
            cursor = next
        }
        return latest
    }

    private func clamped(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
