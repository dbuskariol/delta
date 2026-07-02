import XCTest
@testable import DeltaCore

final class BackupCoordinatorPolicyTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testRunDueBackupsSkipsWhenLowPowerModeIsEnabledAndProfileDisallowsIt() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(
            runner: runner,
            powerState: PowerState(isOnBatteryPower: false, isLowPowerModeEnabled: true)
        )
        let profile = fixture.profile(schedule: BackupSchedule(runInLowPowerMode: false))
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)

        let runs = try coordinator.runDueBackups(now: Date())

        XCTAssertTrue(runs.isEmpty)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(try fixture.database.fetchEvents().contains { $0.message.contains("Low Power Mode") })
    }

    func testRunBackupFailsClosedForInvalidProfile() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let invalidProfile = BackupProfile(
            name: " ",
            sourceMode: .customFolders,
            sources: [BackupSource(path: fixture.source.path)],
            repositoryID: fixture.repository.id
        )

        let run = try coordinator.runBackup(profile: invalidProfile, repository: fixture.repository)

        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.message?.localizedCaseInsensitiveContains("profile is invalid") == true)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(try fixture.database.fetchJobLogs(jobID: run.id).contains { $0.message.contains("profile is invalid") })
    }

    func testPruneRunsRepositoryCheckWhenRetentionRequestsIt() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile(retention: RetentionPolicy(checkAfterPrune: true))

        let pruneRun = try coordinator.forgetAndPrune(profile: profile, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(pruneRun.status, .succeeded)
        XCTAssertEqual(runner.commands.map { $0.arguments.first(where: { ["forget", "check"].contains($0) }) }, ["forget", "check"])
        XCTAssertEqual(jobs.filter { $0.kind == .prune }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .check }.count, 1)
    }

    func testPruneDoesNotRunCheckWhenPruneIsDisabled() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile(retention: RetentionPolicy(pruneAfterForget: false, checkAfterPrune: true))

        _ = try coordinator.forgetAndPrune(profile: profile, repository: fixture.repository)

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["forget"])
    }

    func testSuccessfulRepositoryCheckUpdatesLastVerifiedAt() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        try fixture.database.saveRepository(fixture.repository)

        let checkRun = try coordinator.check(repository: fixture.repository)
        let storedRepository = try XCTUnwrap(fixture.database.fetchRepositories().first { $0.id == fixture.repository.id })

        XCTAssertEqual(checkRun.status, .succeeded)
        XCTAssertNotNil(storedRepository.lastVerifiedAt)
    }

    func testFailedRepositoryCheckDoesNotUpdateLastVerifiedAt() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [ResticRunResult(exitCode: 1, standardOutput: "", standardError: "check failed")])
        let coordinator = fixture.makeCoordinator(runner: runner)
        try fixture.database.saveRepository(fixture.repository)

        let checkRun = try coordinator.check(repository: fixture.repository)
        let storedRepository = try XCTUnwrap(fixture.database.fetchRepositories().first { $0.id == fixture.repository.id })

        XCTAssertEqual(checkRun.status, .failed)
        XCTAssertNil(storedRepository.lastVerifiedAt)
    }

    func testRecoverAbandonedRunningJobsMarksUnlockedJobInterrupted() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()
        let job = JobRun(
            profileID: profile.id,
            repositoryID: fixture.repository.id,
            kind: .backup,
            status: .running
        )
        try fixture.database.saveJobRun(job)

        let recovered = try coordinator.recoverAbandonedRunningJobs()
        let storedJob = try XCTUnwrap(fixture.database.fetchJobRuns(limit: 10).first { $0.id == job.id })
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)
        let events = try fixture.database.fetchEvents(limit: 10)

        XCTAssertEqual(recovered.map(\.id), [job.id])
        XCTAssertEqual(storedJob.status, .cancelled)
        XCTAssertNotNil(storedJob.finishedAt)
        XCTAssertTrue(storedJob.message?.localizedCaseInsensitiveContains("interrupted") == true, storedJob.message ?? "")
        XCTAssertTrue(logs.contains { $0.message.localizedCaseInsensitiveContains("interrupted") })
        XCTAssertTrue(events.contains { $0.message.localizedCaseInsensitiveContains("interrupted") })
    }

    func testRecoverAbandonedRunningJobsLeavesLockedJobRunning() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()
        let job = JobRun(
            profileID: profile.id,
            repositoryID: fixture.repository.id,
            kind: .backup,
            status: .running
        )
        try fixture.database.saveJobRun(job)
        let lock = try XCTUnwrap(fixture.lockManager.acquire(repositoryID: fixture.repository.id))

        let recovered = try withExtendedLifetime(lock) {
            try coordinator.recoverAbandonedRunningJobs()
        }
        let storedJob = try XCTUnwrap(fixture.database.fetchJobRuns(limit: 10).first { $0.id == job.id })

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(storedJob.status, .running)
        XCTAssertNil(storedJob.finishedAt)
    }

    func testRunBackupPreparesMissingLocalDestinationBeforeFirstBackup() throws {
        let fixture = try Fixture(repositoryPrepared: false)
        let runner = MockResticRunner(results: [.success, .success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["init", "backup", "snapshots"])
        XCTAssertEqual(jobs.filter { $0.kind == .initializeRepository && $0.status == .succeeded }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .backup && $0.status == .succeeded }.count, 1)
    }

    func testSuccessfulBackupRefreshesRestorePointCache() throws {
        let fixture = try Fixture()
        let snapshotID = "snapshot-\(UUID().uuidString)"
        let snapshotOutput = """
        [{
          "time": "2026-07-02T08:30:00Z",
          "tree": "tree-id",
          "paths": ["\(fixture.source.path)"],
          "hostname": "mac",
          "username": "me",
          "id": "\(snapshotID)",
          "tags": ["delta"]
        }]
        """
        let runner = MockResticRunner(results: [.success, ResticRunResult(exitCode: 0, standardOutput: snapshotOutput, standardError: "")])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let snapshots = try fixture.database.fetchSnapshots(repositoryID: fixture.repository.id)

        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "snapshots"])
        XCTAssertEqual(snapshots.map(\.id), [snapshotID])
    }

    func testSuccessfulBackupPersistsStructuredSummaryWithoutFullStdout() throws {
        let fixture = try Fixture()
        let snapshotID = "snapshot-\(UUID().uuidString)"
        let backupOutput = """
        {"message_type":"status","files_done":12,"total_files":100}
        {"message_type":"summary","files_new":4,"files_changed":2,"files_unmodified":94,"data_added":2048,"total_files_processed":100,"total_bytes_processed":4096,"snapshot_id":"\(snapshotID)"}
        """
        let runner = MockResticRunner(results: [
            ResticRunResult(exitCode: 0, standardOutput: backupOutput, standardError: ""),
            .emptySnapshotList
        ])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let storedJob = try XCTUnwrap(try fixture.database.fetchJobRuns(limit: 10).first { $0.id == job.id })

        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(storedJob.backupSummary?.filesNew, 4)
        XCTAssertEqual(storedJob.backupSummary?.filesChanged, 2)
        XCTAssertEqual(storedJob.backupSummary?.snapshotID, snapshotID)
        XCTAssertEqual(storedJob.message, "Backup summary · 4 new · 2 changed · 94 unchanged · 2 KB added")
        XCTAssertFalse(storedJob.message?.contains("files_done") == true)
    }

    func testRunBackupReportsCancelledWhenPreparationIsPaused() throws {
        let fixture = try Fixture(repositoryPrepared: false)
        let runner = MockResticRunner(results: [
            ResticRunResult(exitCode: 130, standardOutput: "", standardError: "", stopReason: .pause)
        ])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)

        XCTAssertEqual(job.status, .cancelled)
        XCTAssertEqual(job.stopReason, .pause)
        XCTAssertTrue(job.message?.localizedCaseInsensitiveContains("paused") == true, job.message ?? "")
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["init"])
        XCTAssertEqual(jobs.filter { $0.kind == .initializeRepository && $0.status == .cancelled }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .backup && $0.status == .cancelled }.count, 1)
        XCTAssertTrue(logs.contains { $0.message.localizedCaseInsensitiveContains("paused") })
    }

    func testRunBackupHonorsPersistentStopRequestFromControlStore() throws {
        let fixture = try Fixture()
        let store = ResticRunControlStore(directoryProvider: { fixture.root.appendingPathComponent("controls", isDirectory: true) })
        let capturedJobID = LockedValue<UUID?>(nil)
        let runner = ControlledMockResticRunner { stopReasonProvider in
            let jobID = try XCTUnwrap(capturedJobID.value)
            try store.requestStop(jobID: jobID, reason: .pause)
            return ResticRunResult(
                exitCode: 130,
                standardOutput: "",
                standardError: "",
                stopReason: stopReasonProvider?()
            )
        }
        let coordinator = fixture.makeCoordinator(
            runner: runner,
            runControlStore: store,
            outputHandler: { jobID, _ in
                capturedJobID.value = jobID
            }
        )
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)

        XCTAssertEqual(job.status, .cancelled)
        XCTAssertEqual(job.stopReason, .pause)
        XCTAssertTrue(job.message?.localizedCaseInsensitiveContains("paused") == true, job.message ?? "")
        XCTAssertNil(try store.stopRequest(for: job.id))
    }

    func testRefreshSnapshotsUsesFriendlyRepositoryMissingMessage() throws {
        let fixture = try Fixture()
        let rawError = """
        {"message_type":"exit_error","code":10,"message":"Fatal: repository does not exist: unable to open config file"}
        """
        let runner = MockResticRunner(results: [ResticRunResult(exitCode: 10, standardOutput: "", standardError: rawError)])
        let coordinator = fixture.makeCoordinator(runner: runner)

        XCTAssertThrowsError(try coordinator.refreshSnapshots(repository: fixture.repository)) { error in
            XCTAssertTrue(error.localizedDescription.contains("destination has not been prepared"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("message_type"), error.localizedDescription)
        }
    }

    func testListSnapshotEntriesUsesResticLsAndParsesEntries() throws {
        let fixture = try Fixture()
        let output = """
        {"name":"source","type":"dir","path":"\(fixture.source.path)","message_type":"node","struct_type":"node"}
        {"name":"file.txt","type":"file","path":"\(fixture.source.appendingPathComponent("file.txt").path)","size":128,"message_type":"node","struct_type":"node"}
        """
        let runner = MockResticRunner(results: [ResticRunResult(exitCode: 0, standardOutput: output, standardError: "")])
        let coordinator = fixture.makeCoordinator(runner: runner)

        let entries = try coordinator.listSnapshotEntries(
            repository: fixture.repository,
            snapshotID: "abc123",
            directoryPath: fixture.source.path
        )

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["ls"])
        XCTAssertTrue(runner.commands[0].arguments.contains(fixture.source.path))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].name, "file.txt")
        XCTAssertEqual(entries[1].type, .file)
    }

    func testScheduledMaintenanceRunsCleanupAndCheckWhenDue() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .emptySnapshotList, .success, .success])
        let coordinator = fixture.makeCoordinator(runner: runner, scheduleEvaluator: ScheduleEvaluator(calendar: Self.utc))
        let createdAt = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 0)))
        let now = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 2, minute: 5)))
        let profile = fixture.profile(
            retention: RetentionPolicy(
                maintenanceSchedule: RetentionMaintenanceSchedule(intervalDays: 1, hour: 2, minute: 0)
            ),
            createdAt: createdAt
        )
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)

        let runs = try coordinator.runDueBackups(now: now)

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "snapshots", "forget", "check"])
        XCTAssertEqual(runs.map(\.kind), [.backup, .prune, .check])
    }

    func testScheduledMaintenanceDoesNotRunBeforeConfiguredTime() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .emptySnapshotList])
        let coordinator = fixture.makeCoordinator(runner: runner, scheduleEvaluator: ScheduleEvaluator(calendar: Self.utc))
        let createdAt = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 0)))
        let now = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 30)))
        let profile = fixture.profile(
            retention: RetentionPolicy(
                maintenanceSchedule: RetentionMaintenanceSchedule(intervalDays: 1, hour: 2, minute: 0)
            ),
            createdAt: createdAt
        )
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)

        let runs = try coordinator.runDueBackups(now: now)

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "snapshots"])
        XCTAssertEqual(runs.map(\.kind), [.backup])
    }

    func testScheduledMaintenanceSurfacesPostPruneCheckFailure() throws {
        let fixture = try Fixture()
        let checkFailure = ResticRunResult(exitCode: 1, standardOutput: "", standardError: "repository check failed")
        let runner = MockResticRunner(results: [.success, .emptySnapshotList, .success, checkFailure])
        let coordinator = fixture.makeCoordinator(runner: runner, scheduleEvaluator: ScheduleEvaluator(calendar: Self.utc))
        let createdAt = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 0)))
        let now = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 2, minute: 5)))
        let profile = fixture.profile(
            retention: RetentionPolicy(
                maintenanceSchedule: RetentionMaintenanceSchedule(intervalDays: 1, hour: 2, minute: 0)
            ),
            createdAt: createdAt
        )
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)

        let runs = try coordinator.runDueBackups(now: now)

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "snapshots", "forget", "check"])
        XCTAssertEqual(runs.map(\.status), [.succeeded, .succeeded, .failed])
    }

    func testRestoreRunsRequestedPreRestoreBackupBeforeRestore() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .emptySnapshotList, .success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .chosenFolder(fixture.root.appendingPathComponent("restore").path),
            dryRun: false,
            preRestoreBackupProfileID: profile.id
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(restoreRun.status, .succeeded)
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "snapshots", "restore"])
        XCTAssertEqual(jobs.filter { $0.kind == .backup }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .restore }.count, 1)
    }

    func testRestoreDoesNotStartWhenPreRestoreBackupFails() throws {
        let fixture = try Fixture()
        let backupFailure = ResticRunResult(exitCode: 1, standardOutput: "", standardError: "permission denied")
        let runner = MockResticRunner(results: [backupFailure])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()
        try fixture.database.saveRepository(fixture.repository)
        try fixture.database.saveProfile(profile)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .chosenFolder(fixture.root.appendingPathComponent("restore").path),
            dryRun: false,
            preRestoreBackupProfileID: profile.id
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(restoreRun.status, .failed)
        XCTAssertEqual(restoreRun.message, "Restore was not started because the pre-restore backup did not complete successfully.")
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup"])
        XCTAssertEqual(jobs.filter { $0.kind == .backup && $0.status == .failed }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .restore && $0.status == .failed }.count, 1)
    }

    func testDryRunRestoreDoesNotRunPreRestoreBackup() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .chosenFolder(fixture.root.appendingPathComponent("restore").path),
            dryRun: true,
            preRestoreBackupProfileID: UUID()
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)

        XCTAssertEqual(restoreRun.status, .succeeded)
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["restore"])
    }

    func testOriginalPathRestoreRequiresExplicitConfirmation() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .originalPaths,
            dryRun: false
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(restoreRun.status, .failed)
        XCTAssertEqual(restoreRun.message, "Restore was not started because original-path restore was not explicitly confirmed.")
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(jobs.filter { $0.kind == .restore && $0.status == .failed }.count, 1)
    }

    func testConfirmedOriginalPathRestoreRunsRestic() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .originalPaths,
            dryRun: false,
            confirmedOriginalPathRestore: true
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)

        XCTAssertEqual(restoreRun.status, .succeeded)
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["restore"])
        XCTAssertTrue(runner.commands.first?.arguments.contains("/") == true)
    }

    func testRestoreFailsWithoutStartingResticWhenPreRestoreProfileIsMissing() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let request = RestoreRequest(
            repositoryID: fixture.repository.id,
            snapshotID: "latest",
            destination: .chosenFolder(fixture.root.appendingPathComponent("restore").path),
            dryRun: false,
            preRestoreBackupProfileID: UUID()
        )

        let restoreRun = try coordinator.restore(request: request, repository: fixture.repository)
        let jobs = try fixture.database.fetchJobRuns(limit: 10)

        XCTAssertEqual(restoreRun.status, .failed)
        XCTAssertEqual(restoreRun.message, "Restore was not started because the selected pre-restore backup profile no longer exists.")
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(jobs.filter { $0.kind == .restore && $0.status == .failed }.count, 1)
    }

    func testDestinationLockPreventsOverlappingJobsAcrossCoordinators() throws {
        let fixture = try Fixture()
        let heldLock = try XCTUnwrap(fixture.lockManager.acquire(repositoryID: fixture.repository.id))
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)

        withExtendedLifetime(heldLock) {
            XCTAssertEqual(job.status, .failed)
            XCTAssertEqual(job.message, "Destination is busy with another backup, restore, or maintenance job.")
            XCTAssertTrue(runner.commands.isEmpty)
        }
    }

    func testRunBackupRecordsFailureWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = BackupRepository(
            name: "Missing",
            backend: .local(path: fixture.root.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("repo").path)
        )
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: fixture.source.path)],
            repositoryID: unavailableRepository.id
        )

        let job = try coordinator.runBackup(profile: profile, repository: unavailableRepository)
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.message?.contains("Destination is not available") == true, job.message ?? "")
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(try fixture.database.fetchEvents().contains { $0.message.contains("Destination is not available") })
        XCTAssertTrue(logs.contains { $0.stream == .standardError && $0.message.contains("Destination is not available") })
    }

    func testRefreshSnapshotsDoesNotRunResticWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = fixture.unavailableRepository()

        XCTAssertThrowsError(try coordinator.refreshSnapshots(repository: unavailableRepository)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Destination is not available"), error.localizedDescription)
        }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testBrowseRestorePointDoesNotRunResticWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = fixture.unavailableRepository()

        XCTAssertThrowsError(
            try coordinator.listSnapshotEntries(
                repository: unavailableRepository,
                snapshotID: "snapshot",
                directoryPath: fixture.source.path
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Destination is not available"), error.localizedDescription)
        }
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRestoreRecordsFailureWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = fixture.unavailableRepository()
        let request = RestoreRequest(
            repositoryID: unavailableRepository.id,
            snapshotID: "snapshot",
            destination: .chosenFolder(fixture.root.appendingPathComponent("restore").path)
        )

        let job = try coordinator.restore(request: request, repository: unavailableRepository)

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.message?.contains("Destination is not available") == true, job.message ?? "")
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(try fixture.database.fetchJobLogs(jobID: job.id).contains { $0.message.contains("Destination is not available") })
    }

    func testCheckRecordsFailureWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = fixture.unavailableRepository()

        let job = try coordinator.check(repository: unavailableRepository)

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.message?.contains("Destination is not available") == true, job.message ?? "")
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRetentionMaintenanceRecordsFailureWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        let unavailableRepository = fixture.unavailableRepository()
        let profile = fixture.profile()

        let runs = try coordinator.runRetentionMaintenance(profile: profile, repository: unavailableRepository)

        XCTAssertEqual(runs.map(\.kind), [.prune])
        XCTAssertEqual(runs.map(\.status), [.failed])
        XCTAssertTrue(runs.first?.message?.contains("Destination is not available") == true, runs.first?.message ?? "")
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRunDueBackupsDoesNotRunMaintenanceResticWhenDestinationIsUnavailable() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner, scheduleEvaluator: ScheduleEvaluator(calendar: Self.utc))
        let unavailableRepository = fixture.unavailableRepository()
        let createdAt = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 0)))
        let lastBackup = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 20, minute: 0)))
        let now = try XCTUnwrap(Self.utc.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 2, minute: 5)))
        let profile = fixture.profile(
            schedule: BackupSchedule(kind: .daily(hour: 20, minute: 0)),
            retention: RetentionPolicy(
                maintenanceSchedule: RetentionMaintenanceSchedule(intervalDays: 1, hour: 2, minute: 0)
            ),
            createdAt: createdAt
        )
        try fixture.database.saveRepository(unavailableRepository)
        try fixture.database.saveProfile(profile)
        try fixture.database.saveJobRun(
            JobRun(
                profileID: profile.id,
                repositoryID: unavailableRepository.id,
                kind: .backup,
                status: .succeeded,
                startedAt: lastBackup,
                finishedAt: lastBackup
            )
        )

        let runs = try coordinator.runDueBackups(now: now)

        XCTAssertEqual(runs.map(\.kind), [.prune])
        XCTAssertEqual(runs.map(\.status), [.failed])
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRunBackupRecordsFailureWhenSourceBookmarkCannotResolve() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
        let coordinator = fixture.makeCoordinator(runner: runner)
        var profile = fixture.profile()
        profile.sources = [
            BackupSource(
                path: "/private/protected",
                bookmarkData: Data([0x00, 0x01, 0x02]),
                includeSubvolumes: true
            )
        ]

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.message?.contains("Could not access selected backup sources") == true)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(try fixture.database.fetchEvents().contains { $0.message.contains("Could not access selected backup sources") })
        XCTAssertTrue(logs.contains { $0.stream == .standardError && $0.message.contains("Could not access selected backup sources") })
    }

    func testDestinationLockIsReleasedAfterJobCompletes() throws {
        let fixture = try Fixture()
        let firstRunner = MockResticRunner(results: [.success, .emptySnapshotList])
        let secondRunner = MockResticRunner(results: [.success, .emptySnapshotList])
        let profile = fixture.profile()

        _ = try fixture.makeCoordinator(runner: firstRunner).runBackup(profile: profile, repository: fixture.repository)
        _ = try fixture.makeCoordinator(runner: secondRunner).runBackup(profile: profile, repository: fixture.repository)

        XCTAssertEqual(firstRunner.commands.map(\.resticSubcommand), ["backup", "snapshots"])
        XCTAssertEqual(secondRunner.commands.map(\.resticSubcommand), ["backup", "snapshots"])
    }

    func testRunPersistsStreamingJobLogsAndForwardsLiveEvents() throws {
        let fixture = try Fixture()
        let event = ResticOutputEvent(
            date: Date(timeIntervalSince1970: 1_800),
            stream: .standardOutput,
            message: #"{"message_type":"status","percent_done":0.42,"files_done":21,"total_files":50,"bytes_done":1048576}"#
        )
        let runner = MockResticRunner(results: [.success], streamedEvents: [event])
        let recorder = JobOutputRecorder()
        let coordinator = fixture.makeCoordinator(runner: runner) { jobID, event in
            recorder.append(jobID: jobID, event: event)
        }
        let profile = fixture.profile()

        let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)
        let messages = logs.map(\.message)

        XCTAssertEqual(job.status, .succeeded)
        XCTAssertTrue(messages.contains("Source: \(fixture.source.path)"))
        XCTAssertTrue(messages.contains { $0.hasPrefix("Starting Backup:") && $0.contains("<redacted>") })
        XCTAssertTrue(messages.contains("Processed 21 files · 1 MB"))
        XCTAssertTrue(messages.contains("Finished Backup with status succeeded."))
        XCTAssertTrue(recorder.events.contains { $0.jobID == job.id && $0.event.message == "Source: \(fixture.source.path)" })
        XCTAssertTrue(recorder.events.contains { $0.jobID == job.id && $0.event == event })
    }

    func testRunnerThrowMarksJobFailedAndPersistsFailureLog() throws {
        let fixture = try Fixture()
        let runner = ThrowingResticRunner(error: TestRunError.processLaunchFailed)
        let coordinator = fixture.makeCoordinator(runner: runner)
        let profile = fixture.profile()

        XCTAssertThrowsError(try coordinator.runBackup(profile: profile, repository: fixture.repository))

        let job = try XCTUnwrap(fixture.database.fetchJobRuns(limit: 10).first)
        let logs = try fixture.database.fetchJobLogs(jobID: job.id)
        XCTAssertEqual(job.status, .failed)
        XCTAssertNotNil(job.finishedAt)
        XCTAssertTrue(job.message?.contains("process could not be launched") == true)
        XCTAssertTrue(logs.contains { $0.stream == .standardError && $0.message.contains("Failed Backup") })
    }

    func testMockedResticFailuresProduceUserFacingJobMessages() throws {
        let cases: [(String, ResticRunResult, JobStatus, ResticFailureKind, String)] = [
            (
                "repository missing exit code",
                ResticRunResult(exitCode: 10, standardOutput: "", standardError: ""),
                .failed,
                .repositoryMissing,
                "not been prepared"
            ),
            (
                "locked exit code",
                ResticRunResult(exitCode: 11, standardOutput: "", standardError: ""),
                .failed,
                .lockedRepository,
                "already in use"
            ),
            (
                "wrong password exit code",
                ResticRunResult(exitCode: 12, standardOutput: "", standardError: ""),
                .failed,
                .wrongPassword,
                "encryption password"
            ),
            (
                "locked",
                ResticRunResult(exitCode: 1, standardOutput: "", standardError: "repository is already locked by PID 123"),
                .failed,
                .lockedRepository,
                "already in use"
            ),
            (
                "wrong password",
                ResticRunResult(exitCode: 1, standardOutput: "", standardError: "wrong password or no key found"),
                .failed,
                .wrongPassword,
                "encryption password"
            ),
            (
                "missing credentials",
                ResticRunResult(exitCode: 1, standardOutput: "", standardError: "NoCredentialProviders: no valid providers in chain"),
                .failed,
                .missingBackendCredentials,
                "missing required sign-in credentials"
            ),
            (
                "network unavailable",
                ResticRunResult(exitCode: 1, standardOutput: "", standardError: "dial tcp: network is unreachable"),
                .failed,
                .networkUnavailable,
                "network destination is unavailable"
            ),
            (
                "unreadable source",
                ResticRunResult(exitCode: 3, standardOutput: "", standardError: "open /Users/me/Library/Mail: permission denied"),
                .warning,
                .unreadableSourceFiles,
                "some files could not be read"
            ),
            (
                "interrupted",
                ResticRunResult(exitCode: 130, standardOutput: "", standardError: "backup interrupted"),
                .cancelled,
                .interrupted,
                "interrupted"
            )
        ]

        for testCase in cases {
            let fixture = try Fixture()
            let runner = MockResticRunner(results: [testCase.1])
            let coordinator = fixture.makeCoordinator(runner: runner)
            let profile = fixture.profile()

            let job = try coordinator.runBackup(profile: profile, repository: fixture.repository)

            XCTAssertEqual(job.status, testCase.2, testCase.0)
            XCTAssertEqual(testCase.1.failureKind, testCase.3, testCase.0)
            XCTAssertTrue(job.message?.localizedCaseInsensitiveContains(testCase.4) == true, "\(testCase.0): \(job.message ?? "")")
        }
    }
}

private final class MockResticRunner: ResticStreamingRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ResticRunResult]
    private let streamedEvents: [ResticOutputEvent]
    private(set) var commands: [ResticCommand] = []

    init(results: [ResticRunResult], streamedEvents: [ResticOutputEvent] = []) {
        self.results = results
        self.streamedEvents = streamedEvents
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        try run(command, outputHandler: nil)
    }

    func run(_ command: ResticCommand, outputHandler: (@Sendable (ResticOutputEvent) -> Void)?) throws -> ResticRunResult {
        lock.lock()
        commands.append(command)
        let result = results.isEmpty ? .success : results.removeFirst()
        let events = streamedEvents
        lock.unlock()
        for event in events {
            outputHandler?(event)
        }
        return result
    }
}

private final class ControlledMockResticRunner: ResticControlledStreamingRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let resultProvider: (@Sendable ((@Sendable () -> ResticRunStopReason?)?) throws -> ResticRunResult)
    private(set) var commands: [ResticCommand] = []

    init(resultProvider: @escaping @Sendable ((@Sendable () -> ResticRunStopReason?)?) throws -> ResticRunResult) {
        self.resultProvider = resultProvider
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        try run(command, outputHandler: nil, stopReasonProvider: nil)
    }

    func run(_ command: ResticCommand, outputHandler: (@Sendable (ResticOutputEvent) -> Void)?) throws -> ResticRunResult {
        try run(command, outputHandler: outputHandler, stopReasonProvider: nil)
    }

    func run(
        _ command: ResticCommand,
        outputHandler: (@Sendable (ResticOutputEvent) -> Void)?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) throws -> ResticRunResult {
        lock.lock()
        commands.append(command)
        lock.unlock()
        outputHandler?(ResticOutputEvent(stream: .standardOutput, message: "running"))
        return try resultProvider(stopReasonProvider)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class JobOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [(jobID: UUID, event: ResticOutputEvent)] = []

    var events: [(jobID: UUID, event: ResticOutputEvent)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func append(jobID: UUID, event: ResticOutputEvent) {
        lock.lock()
        recordedEvents.append((jobID, event))
        lock.unlock()
    }
}

private final class ThrowingResticRunner: ResticRunning, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        throw error
    }
}

private enum TestRunError: LocalizedError {
    case processLaunchFailed

    var errorDescription: String? {
        switch self {
        case .processLaunchFailed:
            "process could not be launched"
        }
    }
}

private extension ResticRunResult {
    static let success = ResticRunResult(exitCode: 0, standardOutput: "ok", standardError: "")
    static let emptySnapshotList = ResticRunResult(exitCode: 0, standardOutput: "[]", standardError: "")
}

private extension ResticCommand {
    var resticSubcommand: String? {
        arguments.first { ["backup", "forget", "check", "restore", "snapshots", "init", "ls"].contains($0) }
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let lockDirectory: URL
    let lockManager: RepositoryJobLockManager
    let database: DeltaDatabase
    let repository: BackupRepository

    init(repositoryPrepared: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-tests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        let lockDirectoryURL = root.appendingPathComponent("locks", isDirectory: true)
        lockDirectory = lockDirectoryURL
        lockManager = RepositoryJobLockManager(lockDirectoryProvider: { lockDirectoryURL })
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if repositoryPrepared {
            try Data("prepared".utf8).write(to: destination.appendingPathComponent("config"))
        }
        database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        repository = BackupRepository(name: "Destination", backend: .local(path: destination.path))
    }

    func profile(
        schedule: BackupSchedule = BackupSchedule(),
        retention: RetentionPolicy = RetentionPolicy(),
        createdAt: Date = Date()
    ) -> BackupProfile {
        BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: source.path)],
            repositoryID: repository.id,
            schedule: schedule,
            retention: retention,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    func unavailableRepository() -> BackupRepository {
        BackupRepository(
            id: repository.id,
            name: "Unavailable",
            backend: .local(path: root.appendingPathComponent("missing-destination", isDirectory: true).path)
        )
    }

    func makeCoordinator(
        runner: any ResticRunning,
        scheduleEvaluator: ScheduleEvaluator = ScheduleEvaluator(),
        powerState: PowerState = PowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false),
        runControlStore: ResticRunControlStore? = nil,
        outputHandler: (@Sendable (UUID, ResticOutputEvent) -> Void)? = nil
    ) -> BackupCoordinator {
        BackupCoordinator(
            database: database,
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
                secretBridgeURL: URL(fileURLWithPath: "/usr/bin/false")
            ),
            runner: runner,
            scheduleEvaluator: scheduleEvaluator,
            powerStateProvider: PowerStateProvider(currentPowerState: { powerState }),
            lockManager: lockManager,
            runControlStore: runControlStore,
            outputHandler: outputHandler
        )
    }
}
