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
}
