import XCTest
import Darwin
@testable import DeltaCore

final class RepositoryAvailabilityCheckerTests: XCTestCase {
    func testLocalDestinationIsAvailableWhenDirectoryExists() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let repository = BackupRepository(name: "Local", backend: .local(path: fixture.directory.path))

        XCTAssertTrue(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationIsAvailableWhenParentCanCreateChildDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let child = fixture.directory.appendingPathComponent("new-repository", isDirectory: true)

        let repository = BackupRepository(name: "Local", backend: .local(path: child.path))

        XCTAssertTrue(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationRequiresExistingDirectoryWhenCreationIsNotAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let child = fixture.directory.appendingPathComponent("new-repository", isDirectory: true)

        let repository = BackupRepository(name: "Local", backend: .local(path: child.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository, allowingCreation: false))
    }

    func testLocalDestinationRejectsExistingFilePath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: file)

        let repository = BackupRepository(name: "Local", backend: .local(path: file.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationRejectsExistingDirectoryWhenWriteProbeFails() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(chmod(fixture.directory.path, 0o500), 0)
        defer { _ = chmod(fixture.directory.path, 0o700) }

        let repository = BackupRepository(name: "Local", backend: .local(path: fixture.directory.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationRejectsCreatableChildWhenParentWriteProbeFails() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parent = fixture.directory.appendingPathComponent("read-only-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o500), 0)
        defer { _ = chmod(parent.path, 0o700) }
        let child = parent.appendingPathComponent("new-repository", isDirectory: true)

        let repository = BackupRepository(name: "Local", backend: .local(path: child.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationRejectsMissingParent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let missing = fixture.directory
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("repository", isDirectory: true)

        let repository = BackupRepository(name: "Local", backend: .local(path: missing.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository))
    }

    func testLocalDestinationReportsAvailableCapacityForExistingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = BackupRepository(name: "Local", backend: .local(path: fixture.directory.path))
        let capacityBytes: Int64 = 42 * 1_024 * 1_024 * 1_024
        let checker = RepositoryAvailabilityChecker(capacityProvider: { url in
            url.path == fixture.directory.path ? capacityBytes : nil
        })

        XCTAssertEqual(checker.availableCapacityBytes(for: repository), capacityBytes)
    }

    func testLocalDestinationDoesNotReportCapacityForMissingRepositoryWhenCreationIsNotAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let child = fixture.directory.appendingPathComponent("new-repository", isDirectory: true)
        let repository = BackupRepository(name: "Local", backend: .local(path: child.path))
        let checker = RepositoryAvailabilityChecker(capacityProvider: { _ in
            Int64(42 * 1_024 * 1_024 * 1_024)
        })

        XCTAssertNil(checker.availableCapacityBytes(for: repository))
    }
}

private struct Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
