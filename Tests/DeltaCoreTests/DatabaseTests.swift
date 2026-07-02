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
        let job = JobRun(profileID: profile.id, repositoryID: repository.id, kind: .backup, status: .succeeded)
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

        let snapshotsByRepository = try database.fetchSnapshotsByRepository()
        XCTAssertEqual(snapshotsByRepository[repository.id]?.first?.id, "snapshot")
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
}
