import Foundation
import XCTest
@testable import DeltaCore

final class RepositoryJobLockTests: XCTestCase {
    func testTimeMachineSystemAndDestinationLocksHaveIndependentOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-repository-lock-namespaces-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repositoryID = UUID()
        let destinationLocks = RepositoryJobLockManager { directory }
        let systemLocks = TimeMachineSystemOperationLockManager { directory }

        let destinationLock = try XCTUnwrap(destinationLocks.acquire(repositoryID: repositoryID))
        let systemLock = try XCTUnwrap(systemLocks.acquire(repositoryID: repositoryID))
        XCTAssertNil(try destinationLocks.acquire(repositoryID: repositoryID))
        XCTAssertNil(try systemLocks.acquire(repositoryID: repositoryID))

        destinationLock.release()
        XCTAssertNotNil(try destinationLocks.acquire(repositoryID: repositoryID))
        XCTAssertNil(try systemLocks.acquire(repositoryID: repositoryID))
        withExtendedLifetime(systemLock) {}

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testDestinationLockRejectsSubstitutedSymlinkWithoutTouchingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-repository-lock-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("unrelated")
        try Data("unchanged".utf8).write(to: target)
        let repositoryID = UUID()
        let lockURL = directory.appendingPathComponent("\(repositoryID.uuidString).lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)

        XCTAssertThrowsError(
            try RepositoryJobLockManager { directory }.acquire(repositoryID: repositoryID)
        )
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }
}
