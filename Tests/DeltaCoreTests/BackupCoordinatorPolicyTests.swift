import XCTest
@testable import DeltaCore

final class BackupCoordinatorPolicyTests: XCTestCase {
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

private final class MockResticRunner: ResticRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ResticRunResult]
    private(set) var commands: [ResticCommand] = []

    init(results: [ResticRunResult]) {
        self.results = results
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        if results.isEmpty {
            return .success
        }
        return results.removeFirst()
    }
}

private extension ResticRunResult {
    static let success = ResticRunResult(exitCode: 0, standardOutput: "ok", standardError: "")
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
        retention: RetentionPolicy = RetentionPolicy()
    ) -> BackupProfile {
        BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: source.path)],
            repositoryID: repository.id,
            schedule: schedule,
            retention: retention
        )
    }

    func makeCoordinator(
        runner: MockResticRunner,
        powerState: PowerState = PowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false)
    ) -> BackupCoordinator {
        BackupCoordinator(
            database: database,
            commandBuilder: ResticCommandBuilder(
                resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
                secretBridgeURL: URL(fileURLWithPath: "/usr/bin/false")
            ),
            runner: runner,
            powerStateProvider: PowerStateProvider(currentPowerState: { powerState }),
            lockManager: lockManager
        )
    }
}
