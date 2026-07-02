import XCTest
@testable import DeltaCore

final class DatabaseTests: XCTestCase {
    func testRetentionPolicyDecodesOldPayloadWithDefaultMaintenanceSchedule() throws {
        let data = """
        {
          "keepHourly": 24,
          "keepDaily": 30,
          "keepWeekly": 12,
          "keepMonthly": 12,
          "keepYearly": 0,
          "pruneAfterForget": true,
          "checkAfterPrune": true
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(RetentionPolicy.self, from: data)

        XCTAssertEqual(policy.maintenanceSchedule, RetentionMaintenanceSchedule())
    }

    func testBackupProfileDecodesOldPayloadWithDefaultExcludes() throws {
        let repositoryID = UUID()
        let profile = BackupProfile(
            name: "Documents",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repositoryID,
            excludePatterns: ["/custom"]
        )
        let encodedProfile = try JSONEncoder().encode(profile)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedProfile) as? [String: Any])
        payload.removeValue(forKey: "excludePatterns")
        let oldPayload = try JSONSerialization.data(withJSONObject: payload)

        let decodedProfile = try JSONDecoder().decode(BackupProfile.self, from: oldPayload)

        XCTAssertEqual(decodedProfile.repositoryID, repositoryID)
        XCTAssertEqual(decodedProfile.excludePatterns, BackupExcludePolicy.defaultMacOSExcludes)
    }

    func testDatabaseRoundTripsRepositoryProfileAndJob() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Documents",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id
        )
        let job = JobRun(
            profileID: profile.id,
            repositoryID: repository.id,
            kind: .backup,
            status: .succeeded,
            backupSummary: ResticBackupSummary(filesNew: 2, filesChanged: 1, snapshotID: "snapshot"),
            stopReason: .pause
        )
        let snapshot = ResticSnapshot(id: "snapshot", time: Date(), paths: ["/Users/me/Documents"])

        try database.saveRepository(repository)
        try database.saveProfile(profile)
        try database.saveJobRun(job)
        try database.saveSnapshot(snapshot, repositoryID: repository.id)

        let fetchedRepository = try XCTUnwrap(database.fetchRepositories().first)
        XCTAssertEqual(fetchedRepository.id, repository.id)
        XCTAssertEqual(fetchedRepository.name, repository.name)
        XCTAssertEqual(fetchedRepository.backend, repository.backend)

        let fetchedProfile = try XCTUnwrap(database.fetchProfiles().first)
        XCTAssertEqual(fetchedProfile.id, profile.id)
        XCTAssertEqual(fetchedProfile.name, profile.name)
        XCTAssertEqual(fetchedProfile.sources, profile.sources)

        let fetchedJob = try XCTUnwrap(database.fetchJobRuns(limit: 10).first)
        XCTAssertEqual(fetchedJob.id, job.id)
        XCTAssertEqual(fetchedJob.kind, .backup)
        XCTAssertEqual(fetchedJob.status, .succeeded)
        XCTAssertEqual(fetchedJob.backupSummary, job.backupSummary)
        XCTAssertEqual(fetchedJob.stopReason, .pause)

        let snapshotsByRepository = try database.fetchSnapshotsByRepository()
        XCTAssertEqual(snapshotsByRepository[repository.id]?.first?.id, "snapshot")
    }

    func testPausedBackupStateRequiresExplicitPauseStopReason() {
        let repositoryID = UUID()
        let paused = JobRun(repositoryID: repositoryID, kind: .backup, status: .cancelled, stopReason: .pause)
        let cancelled = JobRun(repositoryID: repositoryID, kind: .backup, status: .cancelled, stopReason: .cancel)
        let messageOnly = JobRun(repositoryID: repositoryID, kind: .backup, status: .cancelled, message: "Backup paused.")
        let restorePause = JobRun(repositoryID: repositoryID, kind: .restore, status: .cancelled, stopReason: .pause)

        XCTAssertTrue(paused.isPausedBackup)
        XCTAssertFalse(cancelled.isPausedBackup)
        XCTAssertFalse(messageOnly.isPausedBackup)
        XCTAssertFalse(restorePause.isPausedBackup)
    }

    func testJobLogsRoundTripByJobAndRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Documents",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id
        )
        let job = JobRun(profileID: profile.id, repositoryID: repository.id, kind: .backup, status: .running)
        let entry = JobLogEntry(
            jobID: job.id,
            profileID: profile.id,
            repositoryID: repository.id,
            stream: .standardOutput,
            message: "Progress 42%"
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)
        try database.saveJobRun(job)

        try database.appendJobLog(entry)

        let jobLogs = try database.fetchJobLogs(jobID: job.id)
        let repositoryLogs = try database.fetchJobLogs(repositoryID: repository.id)
        XCTAssertEqual(jobLogs.count, 1)
        XCTAssertEqual(repositoryLogs.count, 1)
        XCTAssertEqual(jobLogs.first?.id, entry.id)
        XCTAssertEqual(jobLogs.first?.jobID, job.id)
        XCTAssertEqual(jobLogs.first?.profileID, profile.id)
        XCTAssertEqual(jobLogs.first?.repositoryID, repository.id)
        XCTAssertEqual(jobLogs.first?.stream, .standardOutput)
        XCTAssertEqual(jobLogs.first?.message, "Progress 42%")
        XCTAssertEqual(repositoryLogs.first?.id, entry.id)
    }

    func testDatabaseHandlesConcurrentAppAndAgentWriters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Delta.sqlite")
        let appDatabase = try DeltaDatabase(url: databaseURL)
        let agentDatabase = try DeltaDatabase(url: databaseURL)
        let errors = ErrorRecorder()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "delta.database.concurrent-writes", attributes: .concurrent)

        for index in 0..<80 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let database = index.isMultiple(of: 2) ? appDatabase : agentDatabase
                    try database.appendEvent(EventLog(level: .info, message: "event \(index)"))
                } catch {
                    errors.append(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(try appDatabase.fetchEvents(limit: 100).count, 80)
    }

    func testSavingExistingProfileUpdatesEditableFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        var profile = BackupProfile(
            name: "Documents",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        profile.name = "Edited Documents"
        profile.schedule = BackupSchedule(kind: .weekly(weekday: 3, hour: 9, minute: 30), isEnabled: false)
        profile.retention = RetentionPolicy(keepHourly: 2, keepDaily: 7, keepWeekly: 4, keepMonthly: 3, keepYearly: 1)
        profile.sources = [BackupSource(path: "/Users/me/Desktop")]
        profile.updatedAt = Date()
        try database.saveProfile(profile)

        let profiles = try database.fetchProfiles()
        let fetchedProfile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(fetchedProfile.id, profile.id)
        XCTAssertEqual(fetchedProfile.name, "Edited Documents")
        XCTAssertEqual(fetchedProfile.schedule, profile.schedule)
        XCTAssertEqual(fetchedProfile.retention, profile.retention)
        XCTAssertEqual(fetchedProfile.sources, profile.sources)
    }

    func testDeletesProfileWithoutDeletingRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Documents",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        try database.deleteProfile(id: profile.id)

        XCTAssertTrue(try database.fetchProfiles().isEmpty)
        XCTAssertEqual(try database.fetchRepositories().first?.id, repository.id)
    }

    func testDeletesRepositoryAndCachedSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let snapshot = ResticSnapshot(id: "snapshot", time: Date(), paths: ["/Users/me/Documents"])
        try database.saveRepository(repository)
        try database.saveSnapshot(snapshot, repositoryID: repository.id)

        try database.deleteRepository(id: repository.id)

        XCTAssertTrue(try database.fetchRepositories().isEmpty)
        XCTAssertTrue(try database.fetchSnapshots(repositoryID: repository.id).isEmpty)
    }

    func testSaveSnapshotsReplacesOnlyThatRepositoryCacheAndSortsNewestFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let primaryRepository = BackupRepository(name: "Primary", backend: .local(path: "/primary"))
        let secondaryRepository = BackupRepository(name: "Secondary", backend: .local(path: "/secondary"))
        try database.saveRepository(primaryRepository)
        try database.saveRepository(secondaryRepository)
        try database.saveSnapshots(
            [
                ResticSnapshot(id: "old-primary", time: Date(timeIntervalSince1970: 10), paths: ["/Users/me/Documents"]),
                ResticSnapshot(id: "new-primary", time: Date(timeIntervalSince1970: 30), paths: ["/Users/me/Desktop"])
            ],
            repositoryID: primaryRepository.id
        )
        try database.saveSnapshots(
            [
                ResticSnapshot(id: "secondary", time: Date(timeIntervalSince1970: 20), paths: ["/Users/me/Pictures"])
            ],
            repositoryID: secondaryRepository.id
        )

        try database.saveSnapshots(
            [
                ResticSnapshot(id: "replacement-primary", time: Date(timeIntervalSince1970: 40), paths: ["/Users/me/Projects"])
            ],
            repositoryID: primaryRepository.id
        )

        XCTAssertEqual(try database.fetchSnapshots(repositoryID: primaryRepository.id).map(\.id), ["replacement-primary"])
        XCTAssertEqual(try database.fetchSnapshots(repositoryID: secondaryRepository.id).map(\.id), ["secondary"])

        try database.saveSnapshots(
            [
                ResticSnapshot(id: "older-primary", time: Date(timeIntervalSince1970: 50), paths: ["/Users/me/Archive"]),
                ResticSnapshot(id: "newer-primary", time: Date(timeIntervalSince1970: 60), paths: ["/Users/me/Documents"])
            ],
            repositoryID: primaryRepository.id
        )

        let snapshotsByRepository = try database.fetchSnapshotsByRepository()
        XCTAssertEqual(snapshotsByRepository[primaryRepository.id]?.map(\.id), ["newer-primary", "older-primary"])
        XCTAssertEqual(snapshotsByRepository[secondaryRepository.id]?.map(\.id), ["secondary"])
    }
}

private final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedErrors: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }

    func append(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }
}
