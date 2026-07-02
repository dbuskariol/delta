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

public struct BackupSourceHealthEvaluator: Sendable {
    public var bookmarkStore: SecurityScopedBookmarkStore
    public var sourceAccessChecker: BackupSourceAccessChecker

    public init(
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        sourceAccessChecker: BackupSourceAccessChecker = BackupSourceAccessChecker()
    ) {
        self.bookmarkStore = bookmarkStore
        self.sourceAccessChecker = sourceAccessChecker
    }

    public func warnings(
        profiles: [BackupProfile],
        limit: Int = 4
    ) -> [DashboardHealthWarning] {
        profiles
            .compactMap { warning(for: $0) }
            .prefix(limit)
            .map { $0 }
    }

    private func warning(for profile: BackupProfile) -> DashboardHealthWarning? {
        let resolvedSources: [ResolvedSecurityScopedURL]
        do {
            resolvedSources = try profile.sources.map { try bookmarkStore.resolve($0) }
        } catch {
            return DashboardHealthWarning(
                id: "\(profile.id.uuidString)-source-access",
                title: "\(profile.name) source needs access",
                detail: "Delta cannot access one of this profile's selected sources. Rechoose the folder or check Full Disk Access.",
                isCritical: true
            )
        }
        defer {
            for source in resolvedSources {
                source.stopAccessing()
            }
        }

        let resolvedBackupSources = zip(profile.sources, resolvedSources).map { original, resolved in
            BackupSource(
                id: original.id,
                path: resolved.url.path,
                bookmarkData: original.bookmarkData,
                includeSubvolumes: original.includeSubvolumes
            )
        }

        do {
            try sourceAccessChecker.validate(resolvedBackupSources)
            return nil
        } catch {
            return DashboardHealthWarning(
                id: "\(profile.id.uuidString)-source-access",
                title: "\(profile.name) source needs attention",
                detail: error.localizedDescription,
                isCritical: true
            )
        }
    }
}

public struct DashboardHealthEvaluator: Sendable {
    public var availabilityChecker: RepositoryAvailabilityChecker
    public var sourceHealthEvaluator: BackupSourceHealthEvaluator

    public init(
        availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker(),
        sourceHealthEvaluator: BackupSourceHealthEvaluator = BackupSourceHealthEvaluator()
    ) {
        self.availabilityChecker = availabilityChecker
        self.sourceHealthEvaluator = sourceHealthEvaluator
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
        freeSpaceThreshold: DestinationFreeSpaceWarningThreshold = .off,
        now: Date = Date(),
        limit: Int = 4
    ) -> [DashboardHealthWarning] {
        repositories
            .compactMap { warning(for: $0, threshold: threshold, freeSpaceThreshold: freeSpaceThreshold, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    public func sourceWarnings(
        profiles: [BackupProfile],
        limit: Int = 4
    ) -> [DashboardHealthWarning] {
        sourceHealthEvaluator.warnings(profiles: profiles, limit: limit)
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
        freeSpaceThreshold: DestinationFreeSpaceWarningThreshold,
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

        if let minimumBytes = freeSpaceThreshold.minimumBytes,
           let availableBytes = availabilityChecker.availableCapacityBytes(for: repository),
           availableBytes < minimumBytes {
            return DashboardHealthWarning(
                id: "\(repository.id.uuidString)-low-space",
                title: "\(repository.name) is low on space",
                detail: "\(formattedCapacity(availableBytes)) available; Settings warns below \(freeSpaceThreshold.title).",
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

    private func formattedCapacity(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}
