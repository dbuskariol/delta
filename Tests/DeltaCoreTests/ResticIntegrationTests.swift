import XCTest
@testable import DeltaCore

final class ResticIntegrationTests: XCTestCase {
    func testLocalRepositoryLifecycleWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["DELTA_RESTIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Set DELTA_RESTIC_INTEGRATION=1 to run restic integration tests.")
        }

        let resticPath = ProcessInfo.processInfo.environment["RESTIC_BINARY"] ?? "/usr/bin/env"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let fullRestore = root.appendingPathComponent("restore-full", isDirectory: true)
        let selectedRestore = root.appendingPathComponent("restore-selected", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "keep me".write(to: nested.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        try "do not restore in selected test".write(to: source.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
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

        let initResult = try runner.run(try builder.initializeRepository(repository: repository))
        XCTAssertEqual(initResult.status, .succeeded)

        let profile = BackupProfile(
            name: "Source",
            sourceMode: .customFolders,
            sources: [BackupSource(path: source.path)],
            repositoryID: repository.id
        )

        let firstBackup = try runner.run(try builder.backup(profile: profile, repository: repository))
        XCTAssertEqual(firstBackup.status, .succeeded)
        XCTAssertEqual(try snapshots(runner: runner, builder: builder, repository: repository).count, 1)

        let unchangedBackup = try runner.run(try builder.backup(profile: profile, repository: repository))
        XCTAssertEqual(unchangedBackup.status, .succeeded)
        let unchangedSummary = try backupSummary(from: unchangedBackup.standardOutput)
        XCTAssertEqual(unchangedSummary["files_new"], 0)
        XCTAssertEqual(unchangedSummary["files_changed"], 0)
        XCTAssertEqual(unchangedSummary["data_blobs"], 0)
        let snapshotCountAfterUnchangedRun = try snapshots(runner: runner, builder: builder, repository: repository).count
        XCTAssertGreaterThanOrEqual(snapshotCountAfterUnchangedRun, 1)

        try "hello-updated".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "selected-updated".write(to: nested.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        let incrementalBackup = try runner.run(try builder.backup(profile: profile, repository: repository))
        XCTAssertEqual(incrementalBackup.status, .succeeded)
        let incrementalSummary = try backupSummary(from: incrementalBackup.standardOutput)
        XCTAssertGreaterThanOrEqual(incrementalSummary["files_changed"] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(incrementalSummary["data_blobs"] ?? 0, 1)

        let createdSnapshots = try snapshots(runner: runner, builder: builder, repository: repository)
        XCTAssertEqual(createdSnapshots.count, snapshotCountAfterUnchangedRun + 1)
        let latestSnapshot = try XCTUnwrap(createdSnapshots.max(by: { $0.time < $1.time }))

        let fullRestoreRequest = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: latestSnapshot.id,
            destination: .chosenFolder(fullRestore.path),
            dryRun: false
        )
        let fullRestoreResult = try runner.run(try builder.restore(request: fullRestoreRequest, repository: repository))
        XCTAssertEqual(fullRestoreResult.status, .succeeded)
        XCTAssertEqual(try contentsOfFirstFile(named: "file.txt", under: fullRestore), "hello-updated")

        let selectedRestoreRequest = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: latestSnapshot.id,
            scope: .selectedPaths([nested.path]),
            destination: .chosenFolder(selectedRestore.path),
            dryRun: false
        )
        let selectedRestoreResult = try runner.run(try builder.restore(request: selectedRestoreRequest, repository: repository))
        XCTAssertEqual(selectedRestoreResult.status, .succeeded)
        XCTAssertEqual(try contentsOfFirstFile(named: "selected.txt", under: selectedRestore), "selected-updated")
        XCTAssertNil(try firstFile(named: "other.txt", under: selectedRestore))

        let checkResult = try runner.run(try builder.check(repository: repository, readDataSubset: "1/100"))
        XCTAssertEqual(checkResult.status, .succeeded)

        let pruneProfile = BackupProfile(
            name: "Source",
            sourceMode: .customFolders,
            sources: [BackupSource(path: source.path)],
            repositoryID: repository.id,
            retention: RetentionPolicy(keepHourly: 1, keepDaily: 0, keepWeekly: 0, keepMonthly: 0, keepYearly: 0, checkAfterPrune: false)
        )
        let pruneResult = try runner.run(try builder.forgetAndPrune(profile: pruneProfile, repository: repository))
        XCTAssertEqual(pruneResult.status, .succeeded)
        XCTAssertEqual(try snapshots(runner: runner, builder: builder, repository: repository).count, 1)

        let postPruneCheck = try runner.run(try builder.check(repository: repository, readDataSubset: "1/100"))
        XCTAssertEqual(postPruneCheck.status, .succeeded)
    }

    private func snapshots(
        runner: ResticRunner,
        builder: ResticCommandBuilder,
        repository: BackupRepository
    ) throws -> [ResticSnapshot] {
        let result = try runner.run(try builder.snapshots(repository: repository))
        XCTAssertEqual(result.status, .succeeded)
        return try ResticJSONParser().parseSnapshots(from: result.standardOutput)
    }

    private func backupSummary(from output: String) throws -> [String: Int] {
        for line in output.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8) else { continue }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["message_type"] as? String == "summary"
            else {
                continue
            }
            var summary: [String: Int] = [:]
            for key in ["files_new", "files_changed", "files_unmodified", "data_blobs", "tree_blobs"] {
                if let value = object[key] as? Int {
                    summary[key] = value
                }
            }
            return summary
        }
        throw ResticIntegrationError.missingBackupSummary
    }

    private func contentsOfFirstFile(named name: String, under root: URL) throws -> String? {
        guard let file = try firstFile(named: name, under: root) else {
            return nil
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func firstFile(named name: String, under root: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return nil
        }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == name else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                return url
            }
        }
        return nil
    }
}

private enum ResticIntegrationError: Error {
    case missingBackupSummary
}
