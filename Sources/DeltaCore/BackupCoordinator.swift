import Foundation

public final class BackupCoordinator: @unchecked Sendable {
    private let database: DeltaDatabase
    private let commandBuilder: ResticCommandBuilder
    private let runner: any ResticRunning
    private let parser: ResticJSONParser
    private let availabilityChecker: RepositoryAvailabilityChecker
    private let scheduleEvaluator: ScheduleEvaluator
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let powerStateProvider: PowerStateProvider
    private let lockManager: any RepositoryLocking

    public init(
        database: DeltaDatabase,
        commandBuilder: ResticCommandBuilder,
        runner: any ResticRunning = ResticRunner(),
        parser: ResticJSONParser = ResticJSONParser(),
        availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker(),
        scheduleEvaluator: ScheduleEvaluator = ScheduleEvaluator(),
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        powerStateProvider: PowerStateProvider = PowerStateProvider(),
        lockManager: any RepositoryLocking = RepositoryJobLockManager()
    ) {
        self.database = database
        self.commandBuilder = commandBuilder
        self.runner = runner
        self.parser = parser
        self.availabilityChecker = availabilityChecker
        self.scheduleEvaluator = scheduleEvaluator
        self.bookmarkStore = bookmarkStore
        self.powerStateProvider = powerStateProvider
        self.lockManager = lockManager
    }

    @discardableResult
    public func initializeRepository(_ repository: BackupRepository) throws -> JobRun {
        try run(repositoryID: repository.id, profileID: nil, kind: .initializeRepository) {
            try commandBuilder.initializeRepository(repository: repository)
        }
    }

    @discardableResult
    public func runBackup(profile: BackupProfile, repository: BackupRepository) throws -> JobRun {
        guard availabilityChecker.isAvailable(repository) else {
            let run = JobRun(
                profileID: profile.id,
                repositoryID: repository.id,
                kind: .backup,
                status: .failed,
                finishedAt: Date(),
                message: "Destination is not available."
            )
            try database.saveJobRun(run)
            return run
        }

        let resolvedSources = try profile.sources.map { try bookmarkStore.resolve($0) }
        defer {
            for source in resolvedSources {
                source.stopAccessing()
            }
        }
        var resolvedProfile = profile
        resolvedProfile.sources = zip(profile.sources, resolvedSources).map { original, resolved in
            BackupSource(id: original.id, path: resolved.url.path, bookmarkData: original.bookmarkData, includeSubvolumes: original.includeSubvolumes)
        }

        return try run(repositoryID: repository.id, profileID: profile.id, kind: .backup) {
            try commandBuilder.backup(profile: resolvedProfile, repository: repository)
        }
    }

    @discardableResult
    public func refreshSnapshots(repository: BackupRepository) throws -> [ResticSnapshot] {
        guard let lock = try lockManager.acquire(repositoryID: repository.id) else {
            throw BackupCoordinatorError.destinationBusy
        }
        defer { withExtendedLifetime(lock) {} }

        let result = try runner.run(try commandBuilder.snapshots(repository: repository))
        guard result.status == .succeeded || result.status == .warning else {
            throw BackupCoordinatorError.resticFailed(result.standardError)
        }
        let snapshots = try parser.parseSnapshots(from: result.standardOutput)
        try database.saveSnapshots(snapshots, repositoryID: repository.id)
        return snapshots
    }

    @discardableResult
    public func restore(request: RestoreRequest, repository: BackupRepository) throws -> JobRun {
        try database.saveRestoreRequest(request)
        return try run(repositoryID: repository.id, profileID: nil, kind: .restore) {
            try commandBuilder.restore(request: request, repository: repository)
        }
    }

    @discardableResult
    public func forgetAndPrune(profile: BackupProfile, repository: BackupRepository) throws -> JobRun {
        let pruneRun = try run(repositoryID: repository.id, profileID: profile.id, kind: .prune) {
            try commandBuilder.forgetAndPrune(profile: profile, repository: repository)
        }
        if profile.retention.checkAfterPrune && (pruneRun.status == .succeeded || pruneRun.status == .warning) {
            _ = try check(repository: repository, readDataSubset: "1/100")
        }
        return pruneRun
    }

    @discardableResult
    public func check(repository: BackupRepository, readDataSubset: String? = nil) throws -> JobRun {
        try run(repositoryID: repository.id, profileID: nil, kind: .check) {
            try commandBuilder.check(repository: repository, readDataSubset: readDataSubset)
        }
    }

    public func runDueBackups(now: Date = Date()) throws -> [JobRun] {
        let repositories = Dictionary(uniqueKeysWithValues: try database.fetchRepositories().map { ($0.id, $0) })
        let jobRuns = try database.fetchJobRuns(limit: 500)
        let profiles = try database.fetchProfiles()

        var runs: [JobRun] = []
        let powerState = powerStateProvider.current()
        for profile in profiles where profile.schedule.isEnabled {
            guard let repository = repositories[profile.repositoryID] else { continue }
            guard profile.schedule.runOnBattery || !powerState.isOnBatteryPower else {
                try database.appendEvent(EventLog(level: .info, message: "Skipped '\(profile.name)' because this Mac is on battery power."))
                continue
            }
            guard profile.schedule.runInLowPowerMode || !powerState.isLowPowerModeEnabled else {
                try database.appendEvent(EventLog(level: .info, message: "Skipped '\(profile.name)' because Low Power Mode is enabled."))
                continue
            }
            let lastRun = jobRuns
                .filter { $0.profileID == profile.id && $0.kind == .backup && ($0.status == .succeeded || $0.status == .warning) }
                .map(\.startedAt)
                .max()
            let decision = scheduleEvaluator.decision(for: profile.schedule, lastRun: lastRun, now: now)
            if decision.isDue {
                runs.append(try runBackup(profile: profile, repository: repository))
            }
        }
        return runs
    }

    private func run(
        repositoryID: UUID,
        profileID: UUID?,
        kind: JobKind,
        makeCommand: () throws -> ResticCommand
    ) throws -> JobRun {
        guard let lock = try lockManager.acquire(repositoryID: repositoryID) else {
            let job = JobRun(
                profileID: profileID,
                repositoryID: repositoryID,
                kind: kind,
                status: .failed,
                finishedAt: Date(),
                message: BackupCoordinatorError.destinationBusy.localizedDescription
            )
            try database.saveJobRun(job)
            try database.appendEvent(EventLog(level: .warning, message: "\(kind.displayName) skipped because the destination is busy."))
            return job
        }
        defer { withExtendedLifetime(lock) {} }

        var job = JobRun(profileID: profileID, repositoryID: repositoryID, kind: kind, status: .running)
        try database.saveJobRun(job)

        let command = try makeCommand()
        let result = try runner.run(command)
        job.status = result.status
        job.finishedAt = Date()
        job.exitCode = result.exitCode
        job.message = result.userFacingMessage
        try database.saveJobRun(job)
        try database.appendEvent(EventLog(level: result.status == .failed ? .error : .info, message: "\(kind.displayName) finished with status \(result.status.rawValue)."))
        return job
    }
}

public enum BackupCoordinatorError: Error, LocalizedError {
    case resticFailed(String)
    case destinationBusy

    public var errorDescription: String? {
        switch self {
        case let .resticFailed(message): "restic failed: \(message)"
        case .destinationBusy: "Destination is busy with another backup, restore, or maintenance job."
        }
    }
}
