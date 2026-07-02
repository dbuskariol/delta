import XCTest
import GRDB
@testable import DeltaCore

final class DatabaseTests: XCTestCase {
    func testCurrentPayloadSchemaRequiresCurrentFields() throws {
        let retentionPayloadWithoutMaintenance = """
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

        XCTAssertThrowsError(try JSONDecoder().decode(RetentionPolicy.self, from: retentionPayloadWithoutMaintenance))

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
        let profilePayloadWithoutExcludes = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(BackupProfile.self, from: profilePayloadWithoutExcludes))
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

    func testRunningJobProgressSnapshotCanBeUpdatedWithoutRawLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let runningJob = JobRun(repositoryID: repository.id, kind: .backup, status: .running)
        let finishedJob = JobRun(repositoryID: repository.id, kind: .backup, status: .succeeded)
        let progress = ResticProgressSnapshot(
            percentDone: 0.42,
            filesDone: 120,
            totalFiles: 300,
            bytesDone: 4096,
            currentPath: "/Users/me/Documents/file.txt",
            displayMessage: "Processed 120 files"
        )

        try database.saveRepository(repository)
        try database.saveJobRun(runningJob)
        try database.saveJobRun(finishedJob)

        try database.updateJobRunProgress(id: runningJob.id, progressSnapshot: progress)
        try database.updateJobRunProgress(
            id: finishedJob.id,
            progressSnapshot: ResticProgressSnapshot(percentDone: 1, displayMessage: "Finished")
        )

        let jobs = try database.fetchJobRuns(limit: 10)
        XCTAssertEqual(jobs.first { $0.id == runningJob.id }?.progressSnapshot, progress)
        XCTAssertNil(jobs.first { $0.id == finishedJob.id }?.progressSnapshot)
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

    func testPruneOperationalHistoryDeletesOldLocalActivityWithoutDeletingRestorePoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Delta.sqlite")
        let database = try DeltaDatabase(url: databaseURL)
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let oldJob = JobRun(repositoryID: repository.id, kind: .backup, status: .succeeded)
        let recentJob = JobRun(repositoryID: repository.id, kind: .backup, status: .succeeded)
        let oldRestore = RestoreRequest(repositoryID: repository.id, snapshotID: "old", destination: .chosenFolder("/tmp/old"))
        let recentRestore = RestoreRequest(repositoryID: repository.id, snapshotID: "recent", destination: .chosenFolder("/tmp/recent"))
        let oldEvent = EventLog(level: .info, message: "old event")
        let recentEvent = EventLog(level: .info, message: "recent event")
        let snapshot = ResticSnapshot(id: "snapshot", time: Date(timeIntervalSince1970: 10), paths: ["/Users/me/Documents"])
        let oldDate = Date(timeIntervalSince1970: 10)
        let recentDate = Date(timeIntervalSince1970: 2_000)
        let cutoff = Date(timeIntervalSince1970: 1_000)

        try database.saveRepository(repository)
        try database.saveJobRun(oldJob)
        try database.saveJobRun(recentJob)
        try database.appendJobLog(JobLogEntry(jobID: oldJob.id, repositoryID: repository.id, date: oldDate, stream: .standardOutput, message: "old"))
        try database.appendJobLog(JobLogEntry(jobID: recentJob.id, repositoryID: repository.id, date: recentDate, stream: .standardOutput, message: "recent"))
        try database.saveRestoreRequest(oldRestore)
        try database.saveRestoreRequest(recentRestore)
        try database.appendEvent(oldEvent)
        try database.appendEvent(recentEvent)
        try database.saveSnapshot(snapshot, repositoryID: repository.id)
        try setUpdatedAt(databaseURL: databaseURL, table: "job_runs", id: oldJob.id, date: oldDate)
        try setUpdatedAt(databaseURL: databaseURL, table: "restore_jobs", id: oldRestore.id, date: oldDate)
        try setUpdatedAt(databaseURL: databaseURL, table: "event_logs", id: oldEvent.id, date: oldDate)

        let result = try database.pruneOperationalHistory(olderThan: cutoff, minimumRecentJobs: 1)

        XCTAssertEqual(result.deletedJobRuns, 1)
        XCTAssertEqual(result.deletedJobLogs, 1)
        XCTAssertEqual(result.deletedRestoreRequests, 1)
        XCTAssertEqual(result.deletedEvents, 1)
        XCTAssertEqual(try database.fetchJobRuns(limit: 10).map(\.id), [recentJob.id])
        XCTAssertEqual(try database.fetchJobLogs(repositoryID: repository.id).map(\.message), ["recent"])
        XCTAssertEqual(try database.fetchRestoreRequests(limit: 10).map(\.id), [recentRestore.id])
        XCTAssertEqual(try database.fetchEvents(limit: 10).map(\.id), [recentEvent.id])
        XCTAssertEqual(try database.fetchSnapshots(repositoryID: repository.id).map(\.id), ["snapshot"])
    }

    func testPruneOperationalHistoryKeepsMinimumRecentJobSummaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Delta.sqlite")
        let database = try DeltaDatabase(url: databaseURL)
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let olderJob = JobRun(repositoryID: repository.id, kind: .backup, status: .succeeded)
        let newestOldJob = JobRun(repositoryID: repository.id, kind: .backup, status: .succeeded)
        try database.saveRepository(repository)
        try database.saveJobRun(olderJob)
        try database.saveJobRun(newestOldJob)
        try setUpdatedAt(databaseURL: databaseURL, table: "job_runs", id: olderJob.id, date: Date(timeIntervalSince1970: 10))
        try setUpdatedAt(databaseURL: databaseURL, table: "job_runs", id: newestOldJob.id, date: Date(timeIntervalSince1970: 20))

        let result = try database.pruneOperationalHistory(olderThan: Date(timeIntervalSince1970: 1_000), minimumRecentJobs: 1)

        XCTAssertEqual(result.deletedJobRuns, 1)
        XCTAssertEqual(try database.fetchJobRuns(limit: 10).map(\.id), [newestOldJob.id])
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

    func testSnapshotIDsAreScopedToRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let primaryRepository = BackupRepository(name: "Primary", backend: .local(path: "/primary"))
        let secondaryRepository = BackupRepository(name: "Secondary", backend: .local(path: "/secondary"))
        let sharedSnapshotID = "shared-restic-snapshot-id"
        try database.saveRepository(primaryRepository)
        try database.saveRepository(secondaryRepository)

        try database.saveSnapshot(
            ResticSnapshot(id: sharedSnapshotID, time: Date(timeIntervalSince1970: 10), paths: ["/Users/me/Documents"]),
            repositoryID: primaryRepository.id
        )
        try database.saveSnapshot(
            ResticSnapshot(id: sharedSnapshotID, time: Date(timeIntervalSince1970: 20), paths: ["/Users/me/Desktop"]),
            repositoryID: secondaryRepository.id
        )

        XCTAssertEqual(try database.fetchSnapshots(repositoryID: primaryRepository.id).map(\.paths), [["/Users/me/Documents"]])
        XCTAssertEqual(try database.fetchSnapshots(repositoryID: secondaryRepository.id).map(\.paths), [["/Users/me/Desktop"]])

        let snapshotsByRepository = try database.fetchSnapshotsByRepository()
        XCTAssertEqual(snapshotsByRepository[primaryRepository.id]?.map(\.id), [sharedSnapshotID])
        XCTAssertEqual(snapshotsByRepository[secondaryRepository.id]?.map(\.id), [sharedSnapshotID])
    }

    func testIncompatibleSnapshotCacheSchemaIsReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Delta.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                repository_id TEXT,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO snapshots (id, repository_id, payload, created_at, updated_at)
                VALUES ('cached', NULL, '{}', '2026-07-02T00:00:00.000Z', '2026-07-02T00:00:00.000Z')
                """
            )
        }

        let database = try DeltaDatabase(url: databaseURL)
        let repository = BackupRepository(name: "Primary", backend: .local(path: "/primary"))
        let snapshot = ResticSnapshot(id: "current", time: Date(timeIntervalSince1970: 60), paths: ["/Users/me/Documents"])

        XCTAssertTrue(try database.fetchSnapshots().isEmpty)

        try database.saveRepository(repository)
        try database.saveSnapshot(snapshot, repositoryID: repository.id)

        XCTAssertEqual(try database.fetchSnapshots(repositoryID: repository.id).map(\.id), ["current"])
    }

    private func setUpdatedAt(databaseURL: URL, table: String, id: UUID, date: Date) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE \(table) SET updated_at = ? WHERE id = ?",
                arguments: [databaseTimestamp(date), id.uuidString]
            )
        }
    }

    private func databaseTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
