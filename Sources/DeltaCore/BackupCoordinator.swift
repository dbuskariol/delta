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
    private let outputHandler: (@Sendable (UUID, ResticOutputEvent) -> Void)?

    public init(
        database: DeltaDatabase,
        commandBuilder: ResticCommandBuilder,
        runner: any ResticRunning = ResticRunner(),
        parser: ResticJSONParser = ResticJSONParser(),
        availabilityChecker: RepositoryAvailabilityChecker = RepositoryAvailabilityChecker(),
        scheduleEvaluator: ScheduleEvaluator = ScheduleEvaluator(),
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        powerStateProvider: PowerStateProvider = PowerStateProvider(),
        lockManager: any RepositoryLocking = RepositoryJobLockManager(),
        outputHandler: (@Sendable (UUID, ResticOutputEvent) -> Void)? = nil
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
        self.outputHandler = outputHandler
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
            let message = "Destination is not available."
            let run = JobRun(
                profileID: profile.id,
                repositoryID: repository.id,
                kind: .backup,
                status: .failed,
                finishedAt: Date(),
                message: message
            )
            try database.saveJobRun(run)
            try database.appendEvent(EventLog(level: .error, message: message))
            recordJobLog(
                jobID: run.id,
                profileID: profile.id,
                repositoryID: repository.id,
                stream: .standardError,
                message: message
            )
            return run
        }

        let resolvedSources: [ResolvedSecurityScopedURL]
        do {
            resolvedSources = try profile.sources.map { try bookmarkStore.resolve($0) }
        } catch {
            let message = "Could not access selected backup sources: \(error.localizedDescription)"
            let run = JobRun(
                profileID: profile.id,
                repositoryID: repository.id,
                kind: .backup,
                status: .failed,
                finishedAt: Date(),
                message: message
            )
            try database.saveJobRun(run)
            try database.appendEvent(EventLog(level: .error, message: message))
            recordJobLog(
                jobID: run.id,
                profileID: profile.id,
                repositoryID: repository.id,
                stream: .standardError,
                message: message
            )
            return run
        }
        defer {
            for source in resolvedSources {
                source.stopAccessing()
            }
        }
        var resolvedProfile = profile
        resolvedProfile.sources = zip(profile.sources, resolvedSources).map { original, resolved in
            BackupSource(id: original.id, path: resolved.url.path, bookmarkData: original.bookmarkData, includeSubvolumes: original.includeSubvolumes)
        }

        if localRepositoryNeedsPreparation(repository) {
            let preparationRun = try initializeRepository(repository)
            guard preparationRun.status == .succeeded || preparationRun.status == .warning else {
                let message = "Backup was not started because the destination could not be prepared."
                let run = JobRun(
                    profileID: profile.id,
                    repositoryID: repository.id,
                    kind: .backup,
                    status: .failed,
                    finishedAt: Date(),
                    message: message
                )
                try database.saveJobRun(run)
                try database.appendEvent(EventLog(level: .error, message: message))
                recordJobLog(
                    jobID: run.id,
                    profileID: profile.id,
                    repositoryID: repository.id,
                    stream: .standardError,
                    message: message
                )
                return run
            }
        }

        return try run(
            repositoryID: repository.id,
            profileID: profile.id,
            kind: .backup,
            initialLogMessages: sourceSummaryMessages(for: resolvedProfile)
        ) {
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
            throw BackupCoordinatorError.resticFailed(result.userFacingMessage)
        }
        let snapshots = try parser.parseSnapshots(from: result.standardOutput)
        try database.saveSnapshots(snapshots, repositoryID: repository.id)
        try markRepositoryVerified(repositoryID: repository.id, at: Date())
        return snapshots
    }

    @discardableResult
    public func restore(request: RestoreRequest, repository: BackupRepository) throws -> JobRun {
        try database.saveRestoreRequest(request)
        if case .originalPaths = request.destination, !request.dryRun, !request.confirmedOriginalPathRestore {
            return try failedRestoreRun(
                repositoryID: repository.id,
                message: "Restore was not started because original-path restore was not explicitly confirmed."
            )
        }
        if !request.dryRun, let preRestoreProfileID = request.preRestoreBackupProfileID {
            let profiles = try database.fetchProfiles()
            let repositories = Dictionary(uniqueKeysWithValues: try database.fetchRepositories().map { ($0.id, $0) })
            guard let profile = profiles.first(where: { $0.id == preRestoreProfileID }) else {
                return try failedRestoreRun(
                    repositoryID: repository.id,
                    message: "Restore was not started because the selected pre-restore backup profile no longer exists."
                )
            }
            guard let backupRepository = repositories[profile.repositoryID] else {
                return try failedRestoreRun(
                    repositoryID: repository.id,
                    message: "Restore was not started because the pre-restore backup destination no longer exists."
                )
            }
            let preRestoreRun = try runBackup(profile: profile, repository: backupRepository)
            guard preRestoreRun.status == .succeeded else {
                return try failedRestoreRun(
                    repositoryID: repository.id,
                    message: "Restore was not started because the pre-restore backup did not complete successfully."
                )
            }
        }
        return try run(repositoryID: repository.id, profileID: nil, kind: .restore) {
            try commandBuilder.restore(request: request, repository: repository)
        }
    }

    @discardableResult
    public func forgetAndPrune(profile: BackupProfile, repository: BackupRepository) throws -> JobRun {
        try runRetentionMaintenance(profile: profile, repository: repository).first ?? skippedMaintenanceRun(profile: profile, repository: repository)
    }

    @discardableResult
    public func runRetentionMaintenance(profile: BackupProfile, repository: BackupRepository) throws -> [JobRun] {
        guard profile.retention.hasKeepRules else {
            let run = skippedMaintenanceRun(profile: profile, repository: repository)
            try database.saveJobRun(run)
            try database.appendEvent(EventLog(level: .warning, message: "Cleanup skipped for '\(profile.name)' because no retention keep rules are configured."))
            return [run]
        }
        let pruneRun = try run(repositoryID: repository.id, profileID: profile.id, kind: .prune) {
            try commandBuilder.forgetAndPrune(profile: profile, repository: repository)
        }
        var runs = [pruneRun]
        if profile.retention.pruneAfterForget && profile.retention.checkAfterPrune && (pruneRun.status == .succeeded || pruneRun.status == .warning) {
            runs.append(try check(repository: repository, readDataSubset: "1/100"))
        }
        return runs
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
            var backupRun: JobRun?
            if decision.isDue {
                let run = try runBackup(profile: profile, repository: repository)
                runs.append(run)
                backupRun = run
            }

            if isMaintenanceDue(for: profile, jobRuns: jobRuns, now: now) {
                if let backupRun, backupRun.status != .succeeded && backupRun.status != .warning {
                    try database.appendEvent(EventLog(level: .warning, message: "Cleanup skipped for '\(profile.name)' because the backup did not complete successfully."))
                    continue
                }
                runs.append(contentsOf: try runRetentionMaintenance(profile: profile, repository: repository))
            }
        }
        return runs
    }

    private func isMaintenanceDue(for profile: BackupProfile, jobRuns: [JobRun], now: Date) -> Bool {
        let lastMaintenanceRun = jobRuns
            .filter { $0.profileID == profile.id && $0.kind == .prune && ($0.status == .succeeded || $0.status == .warning) }
            .compactMap { $0.finishedAt ?? $0.startedAt }
            .max()
        return scheduleEvaluator.maintenanceDecision(
            for: profile.retention.maintenanceSchedule,
            profileCreatedAt: profile.createdAt,
            lastMaintenanceRun: lastMaintenanceRun,
            now: now
        ).isDue
    }

    private func localRepositoryNeedsPreparation(_ repository: BackupRepository) -> Bool {
        guard case let .local(path) = repository.backend else {
            return false
        }
        let expandedPath = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let configPath = URL(fileURLWithPath: expandedPath).appendingPathComponent("config").path
        return !FileManager.default.fileExists(atPath: configPath)
    }

    private func sourceSummaryMessages(for profile: BackupProfile) -> [String] {
        let paths = profile.sources.map(\.path)
        guard !paths.isEmpty else {
            return []
        }

        let sourceLabel = profile.sourceMode == .fullVolume ? "Volume source" : "Source"
        if paths.count == 1, let path = paths.first {
            return ["\(sourceLabel): \(path)"]
        }

        var messages = ["Sources: \(paths.count) selected"]
        messages += paths.prefix(8).map { "\(sourceLabel): \($0)" }
        if paths.count > 8 {
            messages.append("Sources: \(paths.count - 8) more not shown")
        }
        return messages
    }

    private func failedRestoreRun(repositoryID: UUID, message: String) throws -> JobRun {
        let run = JobRun(
            profileID: nil,
            repositoryID: repositoryID,
            kind: .restore,
            status: .failed,
            finishedAt: Date(),
            message: message
        )
        try database.saveJobRun(run)
        try database.appendEvent(EventLog(level: .error, message: message))
        return run
    }

    private func skippedMaintenanceRun(profile: BackupProfile, repository: BackupRepository) -> JobRun {
        JobRun(
            profileID: profile.id,
            repositoryID: repository.id,
            kind: .prune,
            status: .warning,
            finishedAt: Date(),
            message: "Cleanup skipped because this profile has no retention keep rules."
        )
    }

    private func run(
        repositoryID: UUID,
        profileID: UUID?,
        kind: JobKind,
        initialLogMessages: [String] = [],
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
        for message in initialLogMessages {
            recordJobLog(
                jobID: job.id,
                profileID: profileID,
                repositoryID: repositoryID,
                stream: .standardOutput,
                message: message
            )
            outputHandler?(
                job.id,
                ResticOutputEvent(stream: .standardOutput, message: message)
            )
        }

        let command: ResticCommand
        do {
            command = try makeCommand()
        } catch {
            try markJobFailed(
                &job,
                profileID: profileID,
                repositoryID: repositoryID,
                kind: kind,
                message: "Could not start \(kind.displayName): \(error.localizedDescription)"
            )
            throw error
        }
        recordJobLog(
            jobID: job.id,
            profileID: profileID,
            repositoryID: repositoryID,
            stream: .standardOutput,
            message: "Starting \(kind.displayName): \(command.redactedDescription)"
        )

        let result: ResticRunResult
        do {
            if let streamingRunner = runner as? any ResticStreamingRunning {
                let jobID = job.id
                let profileID = profileID
                let repositoryID = repositoryID
                result = try streamingRunner.run(command) { [weak self] event in
                    self?.recordJobLog(
                        jobID: jobID,
                        profileID: profileID,
                        repositoryID: repositoryID,
                        event: event
                    )
                    self?.outputHandler?(jobID, event)
                }
            } else {
                result = try runner.run(command)
            }
        } catch {
            try markJobFailed(
                &job,
                profileID: profileID,
                repositoryID: repositoryID,
                kind: kind,
                message: "Failed \(kind.displayName): \(error.localizedDescription)"
            )
            throw error
        }

        job.status = result.status
        job.finishedAt = Date()
        job.exitCode = result.exitCode
        job.message = result.userFacingMessage
        try database.saveJobRun(job)
        recordJobLog(
            jobID: job.id,
            profileID: profileID,
            repositoryID: repositoryID,
            stream: result.status == .failed ? .standardError : .standardOutput,
            message: "Finished \(kind.displayName) with status \(result.status.rawValue)."
        )
        if job.status == .succeeded || job.status == .warning {
            try markRepositoryVerified(repositoryID: repositoryID, at: job.finishedAt ?? Date())
        }
        try database.appendEvent(EventLog(level: result.status == .failed ? .error : .info, message: "\(kind.displayName) finished with status \(result.status.rawValue)."))
        return job
    }

    private func markJobFailed(
        _ job: inout JobRun,
        profileID: UUID?,
        repositoryID: UUID,
        kind: JobKind,
        message: String
    ) throws {
        job.status = .failed
        job.finishedAt = Date()
        job.message = message
        try database.saveJobRun(job)
        recordJobLog(
            jobID: job.id,
            profileID: profileID,
            repositoryID: repositoryID,
            stream: .standardError,
            message: message
        )
        try database.appendEvent(EventLog(level: .error, message: message))
    }

    private func recordJobLog(
        jobID: UUID,
        profileID: UUID?,
        repositoryID: UUID,
        event: ResticOutputEvent
    ) {
        recordJobLog(
            jobID: jobID,
            profileID: profileID,
            repositoryID: repositoryID,
            date: event.date,
            stream: event.stream,
            message: ResticLogFormatter.displayMessage(for: event.message)
        )
    }

    private func recordJobLog(
        jobID: UUID,
        profileID: UUID?,
        repositoryID: UUID,
        date: Date = Date(),
        stream: ResticOutputStream,
        message: String
    ) {
        let cleanedMessage = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !cleanedMessage.isEmpty else {
            return
        }
        do {
            try database.appendJobLog(
                JobLogEntry(
                    jobID: jobID,
                    profileID: profileID,
                    repositoryID: repositoryID,
                    date: date,
                    stream: stream,
                    message: cleanedMessage
                )
            )
        } catch {
            try? database.appendEvent(EventLog(level: .warning, message: "Could not save job log output: \(error.localizedDescription)"))
        }
    }

    private func markRepositoryVerified(repositoryID: UUID, at date: Date) throws {
        var repositories = try database.fetchRepositories()
        guard let index = repositories.firstIndex(where: { $0.id == repositoryID }) else {
            return
        }
        repositories[index].lastVerifiedAt = date
        try database.saveRepository(repositories[index])
    }
}

public enum BackupCoordinatorError: Error, LocalizedError {
    case resticFailed(String)
    case destinationBusy

    public var errorDescription: String? {
        switch self {
        case let .resticFailed(message): "Backup tool failed: \(message)"
        case .destinationBusy: "Destination is busy with another backup, restore, or maintenance job."
        }
    }
}
