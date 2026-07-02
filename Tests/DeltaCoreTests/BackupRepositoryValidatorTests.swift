import XCTest
@testable import DeltaCore

final class BackupRepositoryValidatorTests: XCTestCase {
    func testValidatesAndNormalizesLocalDestination() throws {
        let fixture = try ValidatorFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.directory.appendingPathComponent("delta-repo", isDirectory: true)

        let result = try BackupRepositoryValidator().validate(
            name: "  Primary Destination  ",
            backend: .local(path: "  \(destination.path)  ")
        )

        XCTAssertEqual(result.name, "Primary Destination")
        XCTAssertEqual(result.backend, .local(path: destination.path))
    }

    func testRejectsRelativeLocalDestination() {
        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Local",
                backend: .local(path: "Backups/Delta")
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .relativeLocalPath("Backups/Delta"))
        }
    }

    func testRejectsUnavailableLocalDestination() throws {
        let fixture = try ValidatorFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.directory
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("delta-repo", isDirectory: true)

        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Local",
                backend: .local(path: missing.path)
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .localDestinationUnavailable(missing.path))
        }
    }

    func testCanNormalizeUnavailableLocalDestinationWhenAvailabilityCheckIsDeferred() throws {
        let fixture = try ValidatorFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.directory
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("delta-repo", isDirectory: true)

        let result = try BackupRepositoryValidator().validate(
            name: "Renamed",
            backend: .local(path: "  \(missing.path)  "),
            validateLocalAvailability: false
        )

        XCTAssertEqual(result.name, "Renamed")
        XCTAssertEqual(result.backend, .local(path: missing.path))
    }

    func testRejectsInvalidRESTURL() {
        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "REST",
                backend: .rest(url: "backup.example.com/repo")
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .invalidURL("backup.example.com/repo"))
        }
    }

    func testRejectsInvalidSFTPPathAndPort() {
        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "SFTP",
                backend: .sftp(host: "nas.local", path: "relative/repo", username: nil, port: nil)
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .invalidSFTPPath("relative/repo"))
        }

        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "SFTP",
                backend: .sftp(host: "nas.local", path: "/repo", username: nil, port: 70_000)
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .invalidPort(70_000))
        }
    }

    func testRejectsRcloneRemoteWithColon() {
        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Cloud",
                backend: .rclone(remote: "drive:", path: "delta")
            )
        ) { error in
            XCTAssertEqual(error as? BackupRepositoryValidationError, .invalidRcloneRemote("drive:"))
        }
    }

    func testNormalizesRemoteBackendFields() throws {
        let result = try BackupRepositoryValidator().validate(
            name: "  S3  ",
            backend: .s3(
                endpoint: "  https://s3.example.com  ",
                bucket: "  delta  ",
                path: "  mac  ",
                region: "  ap-southeast-2  "
            )
        )

        XCTAssertEqual(result.name, "S3")
        XCTAssertEqual(
            result.backend,
            .s3(endpoint: "https://s3.example.com", bucket: "delta", path: "mac", region: "ap-southeast-2")
        )
    }
}

private struct ValidatorFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
