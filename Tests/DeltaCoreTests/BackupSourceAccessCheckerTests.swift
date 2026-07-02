import XCTest
@testable import DeltaCore

final class BackupSourceAccessCheckerTests: XCTestCase {
    func testAllowsReadableFolderSources() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNoThrow(
            try BackupSourceAccessChecker().validate([
                BackupSource(path: directory.path)
            ])
        )
    }

    func testRejectsMissingSources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-missing-source-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try BackupSourceAccessChecker().validate(BackupSource(path: directory.path))) { error in
            XCTAssertEqual(error as? BackupSourceAccessError, .missing(path: directory.path))
        }
    }

    func testRejectsFileSources() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("document.txt")
        try Data("content".utf8).write(to: fileURL)

        XCTAssertThrowsError(try BackupSourceAccessChecker().validate(BackupSource(path: fileURL.path))) { error in
            XCTAssertEqual(error as? BackupSourceAccessError, .notFolder(path: fileURL.path))
        }
    }

    func testRejectsUnreadableSources() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try BackupSourceAccessChecker().validate(BackupSource(path: directory.path))) { error in
            XCTAssertEqual(error as? BackupSourceAccessError, .unreadable(path: directory.path))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-source-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
