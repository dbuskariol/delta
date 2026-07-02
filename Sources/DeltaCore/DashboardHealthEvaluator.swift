import Foundation

public struct DashboardHealthWarning: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var isCritical: Bool

    public init(id: String, title: String, detail: String, isCritical: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isCritical = isCritical
    }
}

public struct DashboardHealthEvaluator: Sendable {
    public var availabilityChecker: RepositoryAvailabilityChecker

    public init(availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker()) {
        self.availabilityChecker = availabilityChecker
    }

    public func backupWarnings(
        profiles: [BackupProfile],
        jobs: [JobRun],
        threshold: BackupFreshnessWarningThreshold,
        now: Date = Date(),
        limit: Int = 4
    ) -> [DashboardHealthWarning] {
        profiles
            .filter { $0.schedule.isEnabled }
            .compactMap { warning(for: $0, jobs: jobs, threshold: threshold, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    public func destinationWarnings(
        repositories: [BackupRepository],
        threshold: DestinationVerificationWarningThreshold,
        now: Date = Date(),
        limit: Int = 4
    ) -> [DashboardHealthWarning] {
        repositories
            .compactMap { warning(for: $0, threshold: threshold, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    private func warning(
        for profile: BackupProfile,
        jobs: [JobRun],
        threshold: BackupFreshnessWarningThreshold,
        now: Date
    ) -> DashboardHealthWarning? {
        let profileJobs = jobs.filter { $0.profileID == profile.id && $0.kind == .backup }
        let latestBackup = profileJobs.max { $0.startedAt < $1.startedAt }
        let latestCompleted = profileJobs
            .filter { $0.status == .succeeded || $0.status == .warning }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }

        if latestBackup?.status == .failed {
            return DashboardHealthWarning(
                id: "\(profile.id.uuidString)-failed",
                title: "\(profile.name) failed",
                detail: latestBackup?.message ?? "The most recent backup did not complete.",
                isCritical: true
            )
        }

        if latestBackup?.status == .cancelled && latestBackup?.stopReason != .pause {
            return DashboardHealthWarning(
                id: "\(profile.id.uuidString)-stopped",
                title: "\(profile.name) was stopped",
                detail: "Run the backup again when the destination is available.",
                isCritical: false
            )
        }

        guard let latestCompleted else {
            return DashboardHealthWarning(
                id: "\(profile.id.uuidString)-missing",
                title: "\(profile.name) has no completed backup",
                detail: "Run this profile once to create its first restore point.",
                isCritical: false
            )
        }

        let completedAt = latestCompleted.finishedAt ?? latestCompleted.startedAt
        guard now.timeIntervalSince(completedAt) > threshold.timeInterval else {
            return nil
        }

        return DashboardHealthWarning(
            id: "\(profile.id.uuidString)-stale",
            title: "\(profile.name) is stale",
            detail: "Last completed backup was \(relativeTime(from: completedAt, to: now)).",
            isCritical: false
        )
    }

    private func warning(
        for repository: BackupRepository,
        threshold: DestinationVerificationWarningThreshold,
        now: Date
    ) -> DashboardHealthWarning? {
        if repository.backend.kind == .local && !availabilityChecker.isAvailable(repository, allowingCreation: false) {
            return DashboardHealthWarning(
                id: "\(repository.id.uuidString)-unavailable",
                title: "\(repository.name) is unavailable",
                detail: "Connect, mount, or prepare this destination before scheduled backups run.",
                isCritical: true
            )
        }

        guard let lastVerifiedAt = repository.lastVerifiedAt else {
            return DashboardHealthWarning(
                id: "\(repository.id.uuidString)-unchecked",
                title: "\(repository.name) has not been checked",
                detail: "Run a destination check to verify backup data is readable.",
                isCritical: false
            )
        }

        guard now.timeIntervalSince(lastVerifiedAt) > threshold.timeInterval else {
            return nil
        }

        return DashboardHealthWarning(
            id: "\(repository.id.uuidString)-verification-stale",
            title: "\(repository.name) check is stale",
            detail: "Last destination check was \(relativeTime(from: lastVerifiedAt, to: now)).",
            isCritical: false
        )
    }

    private func relativeTime(from date: Date, to referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
}
