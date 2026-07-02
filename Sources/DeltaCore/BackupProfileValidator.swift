import Foundation

public enum BackupProfileValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case missingSource
    case emptySourcePath
    case relativeSourcePath(String)
    case missingDestination

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a backup profile name."
        case .missingSource:
            return "Choose at least one source."
        case .emptySourcePath:
            return "Choose a source with a valid path."
        case let .relativeSourcePath(path):
            return "Use an absolute source path, not '\(path)'."
        case .missingDestination:
            return "Choose an existing destination."
        }
    }
}

public struct BackupProfileValidationResult: Equatable, Sendable {
    public var profile: BackupProfile
}

public struct BackupProfileValidator: Sendable {
    public struct Limits: Equatable, Sendable {
        public var keepHourly: ClosedRange<Int>
        public var keepDaily: ClosedRange<Int>
        public var keepWeekly: ClosedRange<Int>
        public var keepMonthly: ClosedRange<Int>
        public var keepYearly: ClosedRange<Int>
        public var maintenanceIntervalDays: ClosedRange<Int>
        public var bandwidthKiB: ClosedRange<Int>

        public init(
            keepHourly: ClosedRange<Int> = 0...168,
            keepDaily: ClosedRange<Int> = 0...365,
            keepWeekly: ClosedRange<Int> = 0...260,
            keepMonthly: ClosedRange<Int> = 0...120,
            keepYearly: ClosedRange<Int> = 0...50,
            maintenanceIntervalDays: ClosedRange<Int> = 1...90,
            bandwidthKiB: ClosedRange<Int> = 1...1_048_576
        ) {
            self.keepHourly = keepHourly
            self.keepDaily = keepDaily
            self.keepWeekly = keepWeekly
            self.keepMonthly = keepMonthly
            self.keepYearly = keepYearly
            self.maintenanceIntervalDays = maintenanceIntervalDays
            self.bandwidthKiB = bandwidthKiB
        }
    }

    public var limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func validate(
        _ profile: BackupProfile,
        knownRepositoryIDs: Set<UUID>? = nil
    ) throws -> BackupProfileValidationResult {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw BackupProfileValidationError.emptyName
        }

        if let knownRepositoryIDs, !knownRepositoryIDs.contains(profile.repositoryID) {
            throw BackupProfileValidationError.missingDestination
        }

        let sources = try normalizedSources(profile.sources)
        guard !sources.isEmpty else {
            throw BackupProfileValidationError.missingSource
        }

        var normalizedProfile = profile
        normalizedProfile.name = name
        normalizedProfile.sources = sources
        normalizedProfile.schedule = normalizedSchedule(profile.schedule)
        normalizedProfile.retention = normalizedRetention(profile.retention)
        normalizedProfile.excludePatterns = normalizedExcludePatterns(profile.excludePatterns)
        return BackupProfileValidationResult(profile: normalizedProfile)
    }

    private func normalizedSources(_ sources: [BackupSource]) throws -> [BackupSource] {
        var normalizedSources: [BackupSource] = []
        var seenPaths = Set<String>()

        for source in sources {
            let trimmed = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw BackupProfileValidationError.emptySourcePath
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw BackupProfileValidationError.relativeSourcePath(trimmed)
            }
            let normalizedPath = normalizedAbsolutePath(expanded)
            guard seenPaths.insert(normalizedPath).inserted else {
                continue
            }
            normalizedSources.append(
                BackupSource(
                    id: source.id,
                    path: normalizedPath,
                    bookmarkData: source.bookmarkData,
                    includeSubvolumes: source.includeSubvolumes
                )
            )
        }

        return normalizedSources
    }

    private func normalizedSchedule(_ schedule: BackupSchedule) -> BackupSchedule {
        BackupSchedule(
            id: schedule.id,
            kind: normalizedScheduleKind(schedule.kind),
            isEnabled: schedule.isEnabled,
            catchUpMissedRuns: schedule.catchUpMissedRuns,
            runOnBattery: schedule.runOnBattery,
            runInLowPowerMode: schedule.runInLowPowerMode,
            uploadLimitKiB: normalizedBandwidth(schedule.uploadLimitKiB),
            downloadLimitKiB: normalizedBandwidth(schedule.downloadLimitKiB)
        )
    }

    private func normalizedScheduleKind(_ kind: ScheduleKind) -> ScheduleKind {
        switch kind {
        case let .hourly(minute):
            return .hourly(minute: clamped(minute, to: 0...59))
        case let .daily(hour, minute):
            return .daily(hour: clamped(hour, to: 0...23), minute: clamped(minute, to: 0...59))
        case let .weekly(weekday, hour, minute):
            return .weekly(
                weekday: clamped(weekday, to: 1...7),
                hour: clamped(hour, to: 0...23),
                minute: clamped(minute, to: 0...59)
            )
        case let .monthly(day, hour, minute):
            return .monthly(
                day: clamped(day, to: 1...31),
                hour: clamped(hour, to: 0...23),
                minute: clamped(minute, to: 0...59)
            )
        case let .customInterval(seconds):
            return .customInterval(seconds: max(60, seconds))
        }
    }

    private func normalizedRetention(_ retention: RetentionPolicy) -> RetentionPolicy {
        RetentionPolicy(
            keepHourly: clamped(retention.keepHourly, to: limits.keepHourly),
            keepDaily: clamped(retention.keepDaily, to: limits.keepDaily),
            keepWeekly: clamped(retention.keepWeekly, to: limits.keepWeekly),
            keepMonthly: clamped(retention.keepMonthly, to: limits.keepMonthly),
            keepYearly: clamped(retention.keepYearly, to: limits.keepYearly),
            pruneAfterForget: retention.pruneAfterForget,
            checkAfterPrune: retention.checkAfterPrune,
            maintenanceSchedule: RetentionMaintenanceSchedule(
                isEnabled: retention.maintenanceSchedule.isEnabled,
                intervalDays: clamped(retention.maintenanceSchedule.intervalDays, to: limits.maintenanceIntervalDays),
                hour: clamped(retention.maintenanceSchedule.hour, to: 0...23),
                minute: clamped(retention.maintenanceSchedule.minute, to: 0...59)
            )
        )
    }

    private func normalizedBandwidth(_ value: Int?) -> Int? {
        guard let value, value >= limits.bandwidthKiB.lowerBound else {
            return nil
        }
        return clamped(value, to: limits.bandwidthKiB)
    }

    private func normalizedExcludePatterns(_ patterns: [String]) -> [String] {
        var seenPatterns = Set<String>()
        let trimmedPatterns = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seenPatterns.insert($0).inserted }
        return BackupExcludePatternParser.mergingDefaults(
            with: BackupExcludePatternParser.customPatterns(from: trimmedPatterns)
        )
    }

    private func normalizedAbsolutePath(_ path: String) -> String {
        guard path != "/" else {
            return "/"
        }
        let trimmedSlashes = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/\(trimmedSlashes)"
    }

    private func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
