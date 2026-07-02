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

    func testScheduledMaintenanceRunsCleanupAndCheckWhenDue() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .success, .success])
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

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "forget", "check"])
        XCTAssertEqual(runs.map(\.kind), [.backup, .prune, .check])
    }

    func testScheduledMaintenanceDoesNotRunBeforeConfiguredTime() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success])
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

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup"])
        XCTAssertEqual(runs.map(\.kind), [.backup])
    }

    func testScheduledMaintenanceSurfacesPostPruneCheckFailure() throws {
        let fixture = try Fixture()
        let checkFailure = ResticRunResult(exitCode: 1, standardOutput: "", standardError: "repository check failed")
        let runner = MockResticRunner(results: [.success, .success, checkFailure])
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

        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "forget", "check"])
        XCTAssertEqual(runs.map(\.status), [.succeeded, .succeeded, .failed])
    }

    func testRestoreRunsRequestedPreRestoreBackupBeforeRestore() throws {
        let fixture = try Fixture()
        let runner = MockResticRunner(results: [.success, .success])
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
        XCTAssertEqual(runner.commands.map(\.resticSubcommand), ["backup", "restore"])
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

    func testDestinationLockIsReleasedAfterJobCompletes() throws {
        let fixture = try Fixture()
        let firstRunner = MockResticRunner(results: [.success])
        let secondRunner = MockResticRunner(results: [.success])
        let profile = fixture.profile()

        _ = try fixture.makeCoordinator(runner: firstRunner).runBackup(profile: profile, repository: fixture.repository)
        _ = try fixture.makeCoordinator(runner: secondRunner).runBackup(profile: profile, repository: fixture.repository)

        XCTAssertEqual(firstRunner.commands.count, 1)
        XCTAssertEqual(secondRunner.commands.count, 1)
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
        XCTAssertTrue(messages.contains { $0.hasPrefix("Starting Backup:") && $0.contains("<redacted>") })
        XCTAssertTrue(messages.contains("Progress 42% · 21/50 files · 1 MB"))
        XCTAssertTrue(messages.contains("Finished Backup with status succeeded."))
        XCTAssertEqual(recorder.events.first?.jobID, job.id)
        XCTAssertEqual(recorder.events.first?.event, event)
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
}

private extension ResticCommand {
    var resticSubcommand: String? {
        arguments.first { ["backup", "forget", "check", "restore", "snapshots", "init"].contains($0) }
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

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-tests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        let lockDirectoryURL = root.appendingPathComponent("locks", isDirectory: true)
        lockDirectory = lockDirectoryURL
        lockManager = RepositoryJobLockManager(lockDirectoryProvider: { lockDirectoryURL })
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
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

    func makeCoordinator(
        runner: any ResticRunning,
        scheduleEvaluator: ScheduleEvaluator = ScheduleEvaluator(),
        powerState: PowerState = PowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false),
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
            outputHandler: outputHandler
        )
    }
}
