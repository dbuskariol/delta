import XCTest
@testable import DeltaCore

final class DashboardHealthEvaluatorTests: XCTestCase {
    func testBackupWarningsCallOutMissingFailedAndStaleScheduledBackups() {
        let now = Date(timeIntervalSince1970: 10_000)
        let repositoryID = UUID()
        let missing = BackupProfile(
            id: UUID(),
            name: "Missing",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repositoryID
        )
        let failed = BackupProfile(
            id: UUID(),
            name: "Failed",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Desktop")],
            repositoryID: repositoryID
        )
        let stale = BackupProfile(
            id: UUID(),
            name: "Stale",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Pictures")],
            repositoryID: repositoryID
        )
        let healthy = BackupProfile(
            id: UUID(),
            name: "Healthy",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Movies")],
            repositoryID: repositoryID
        )
        let jobs = [
            JobRun(
                profileID: failed.id,
                repositoryID: repositoryID,
                kind: .backup,
                status: .failed,
                startedAt: now.addingTimeInterval(-60),
                finishedAt: now.addingTimeInterval(-30),
                message: "Destination is not available."
            ),
            JobRun(
                profileID: stale.id,
                repositoryID: repositoryID,
                kind: .backup,
                status: .succeeded,
                startedAt: now.addingTimeInterval(-4 * 86_400),
                finishedAt: now.addingTimeInterval(-4 * 86_400)
            ),
            JobRun(
                profileID: healthy.id,
                repositoryID: repositoryID,
                kind: .backup,
                status: .succeeded,
                startedAt: now.addingTimeInterval(-3_600),
                finishedAt: now.addingTimeInterval(-3_500)
            )
        ]

        let warnings = DashboardHealthEvaluator().backupWarnings(
            profiles: [missing, failed, stale, healthy],
            jobs: jobs,
            threshold: .threeDays,
            now: now
        )

        XCTAssertEqual(warnings.map(\.title), [
            "Missing has no completed backup",
            "Failed failed",
            "Stale is stale"
        ])
        XCTAssertEqual(warnings.map(\.isCritical), [false, true, false])
        XCTAssertTrue(warnings[1].detail.contains("Destination is not available."))
    }

    func testBackupWarningsIgnoreManualProfilesAndRecentCompletedBackups() {
        let now = Date(timeIntervalSince1970: 10_000)
        let repositoryID = UUID()
        var manual = BackupProfile(
            name: "Manual",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repositoryID
        )
        manual.schedule.isEnabled = false
        let recent = BackupProfile(
            name: "Recent",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Desktop")],
            repositoryID: repositoryID
        )
        let jobs = [
            JobRun(
                profileID: recent.id,
                repositoryID: repositoryID,
                kind: .backup,
                status: .succeeded,
                startedAt: now.addingTimeInterval(-3_600),
                finishedAt: now.addingTimeInterval(-3_500)
            )
        ]

        let warnings = DashboardHealthEvaluator().backupWarnings(
            profiles: [manual, recent],
            jobs: jobs,
            threshold: .oneDay,
            now: now
        )

        XCTAssertTrue(warnings.isEmpty)
    }

    func testDestinationWarningsCallOutUnavailableUncheckedAndStaleDestinations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 100_000)
        let missingPath = fixture.directory.appendingPathComponent("missing", isDirectory: true).path
        let unavailable = BackupRepository(name: "Unmounted", backend: .local(path: missingPath))
        let unchecked = BackupRepository(name: "Unchecked", backend: .local(path: fixture.directory.path))
        let stale = BackupRepository(
            name: "Stale",
            backend: .s3(endpoint: "s3.example.com", bucket: "delta", path: nil, region: nil),
            lastVerifiedAt: now.addingTimeInterval(-31 * 86_400)
        )
        let healthy = BackupRepository(
            name: "Healthy",
            backend: .local(path: fixture.directory.path),
            lastVerifiedAt: now.addingTimeInterval(-86_400)
        )

        let warnings = DashboardHealthEvaluator().destinationWarnings(
            repositories: [unavailable, unchecked, stale, healthy],
            threshold: .thirtyDays,
            now: now
        )

        XCTAssertEqual(warnings.map(\.title), [
            "Unmounted is unavailable",
            "Unchecked has not been checked",
            "Stale check is stale"
        ])
        XCTAssertEqual(warnings.map(\.isCritical), [true, false, false])
    }
}

private struct Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
