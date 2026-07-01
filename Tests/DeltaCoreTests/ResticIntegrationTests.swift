import XCTest
@testable import DeltaCore

final class ResticIntegrationTests: XCTestCase {
    func testLocalRepositoryBackupAndRestoreWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["DELTA_RESTIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Set DELTA_RESTIC_INTEGRATION=1 to run restic integration tests.")
        }

        let resticPath = ProcessInfo.processInfo.environment["RESTIC_BINARY"] ?? "/usr/bin/env"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let restore = root.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = BackupRepository(name: "Integration", backend: .local(path: repo.path), keychainAccount: "test-\(UUID().uuidString)")
        let bridge = root.appendingPathComponent("password-helper.sh")
        try """
        #!/bin/sh
        printf '%s\\n' 'integration-test-password'
        """.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)

        let builder = ResticCommandBuilder(resticExecutableURL: URL(fileURLWithPath: resticPath), secretBridgeURL: bridge)
        let runner = ResticRunner()

        _ = try runner.run(try builder.initializeRepository(repository: repository))
        let profile = BackupProfile(
            name: "Source",
            sourceMode: .customFolders,
            sources: [BackupSource(path: source.path)],
            repositoryID: repository.id
        )
        let backupResult = try runner.run(try builder.backup(profile: profile, repository: repository))
        XCTAssertEqual(backupResult.status, .succeeded)

        let snapshotResult = try runner.run(try builder.snapshots(repository: repository))
        let snapshots = try ResticJSONParser().parseSnapshots(from: snapshotResult.standardOutput)
        XCTAssertFalse(snapshots.isEmpty)

        let restoreRequest = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: snapshots[0].id,
            destination: .chosenFolder(restore.path),
            dryRun: false
        )
        let restoreResult = try runner.run(try builder.restore(request: restoreRequest, repository: repository))
        XCTAssertEqual(restoreResult.status, .succeeded)
    }
}
