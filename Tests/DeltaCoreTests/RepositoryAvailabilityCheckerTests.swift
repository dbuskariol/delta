import XCTest
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

    func testLocalDestinationRejectsMissingParent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let missing = fixture.directory
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("repository", isDirectory: true)

        let repository = BackupRepository(name: "Local", backend: .local(path: missing.path))

        XCTAssertFalse(RepositoryAvailabilityChecker().isAvailable(repository))
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
