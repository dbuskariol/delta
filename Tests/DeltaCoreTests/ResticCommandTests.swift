import XCTest
@testable import DeltaCore

final class ResticCommandTests: XCTestCase {
    func testRedactedDescriptionHidesPasswordCommandValue() {
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/restic"),
            arguments: [
                "-r", "/Volumes/Backup/Delta",
                "--password-command", "'/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge' 'repository-secret-account'",
                "snapshots"
            ]
        )

        let description = command.redactedDescription

        XCTAssertTrue(description.contains("'--password-command' <redacted>"))
        XCTAssertFalse(description.contains("DeltaSecretBridge"))
        XCTAssertFalse(description.contains("repository-secret-account"))
    }

    func testBackendURLBuilderSupportsPrimaryBackends() throws {
        let builder = ResticBackendURLBuilder()

        XCTAssertEqual(try builder.repositoryURL(for: .local(path: "/Volumes/Backup/Delta")), "/Volumes/Backup/Delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "nas.local", path: "/tank/delta", username: "me", port: nil)), "sftp:me@nas.local:/tank/delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "nas.local", path: "/tank/delta", username: "me", port: 2222)), "sftp://me@nas.local:2222//tank/delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "::1", path: "/srv/restic-repo", username: "user", port: 2222)), "sftp://user@[::1]:2222//srv/restic-repo")
        XCTAssertEqual(try builder.repositoryURL(for: .rest(url: "https://restic.example.com/user")), "rest:https://restic.example.com/user")
        XCTAssertEqual(try builder.repositoryURL(for: .s3(endpoint: "s3.us.test", bucket: "delta", path: "mac", region: nil)), "s3:s3.us.test/delta/mac")
        XCTAssertEqual(try builder.repositoryURL(for: .backblazeB2(bucket: "delta", path: "mac")), "b2:delta:mac")
        XCTAssertEqual(try builder.repositoryURL(for: .azureBlob(container: "delta", path: "mac")), "azure:delta:/mac")
        XCTAssertEqual(try builder.repositoryURL(for: .googleCloudStorage(bucket: "delta", path: "mac")), "gs:delta:/mac")
        XCTAssertEqual(try builder.repositoryURL(for: .swiftObjectStorage(container: "delta", path: "mac")), "swift:delta:/mac")
        XCTAssertEqual(try builder.repositoryURL(for: .rclone(remote: "drive", path: "delta")), "rclone:drive:delta")
        XCTAssertEqual(try builder.repositoryURL(for: .custom(repository: "rest:http://localhost:8000/repo")), "rest:http://localhost:8000/repo")
    }

    func testBackendURLBuilderUsesResticRootPathSyntax() throws {
        let builder = ResticBackendURLBuilder()

        XCTAssertEqual(try builder.repositoryURL(for: .backblazeB2(bucket: "delta", path: nil)), "b2:delta:")
        XCTAssertEqual(try builder.repositoryURL(for: .azureBlob(container: "delta", path: nil)), "azure:delta:/")
        XCTAssertEqual(try builder.repositoryURL(for: .googleCloudStorage(bucket: "delta", path: nil)), "gs:delta:/")
        XCTAssertEqual(try builder.repositoryURL(for: .swiftObjectStorage(container: "delta", path: nil)), "swift:delta:")
    }

    func testBackendURLBuilderRequiresS3Endpoint() {
        XCTAssertThrowsError(
            try ResticBackendURLBuilder().repositoryURL(
                for: .s3(endpoint: nil, bucket: "delta", path: nil, region: nil)
            )
        ) { error in
            XCTAssertEqual(error as? ResticBackendError, .emptyRequiredField("S3 endpoint"))
        }
    }

    func testBackendURLBuilderExpandsTypedLocalHomePath() throws {
        let builder = ResticBackendURLBuilder()
        let expected = ("~/DeltaBackups" as NSString).expandingTildeInPath

        XCTAssertEqual(try builder.repositoryURL(for: .local(path: "  ~/DeltaBackups  ")), expected)
    }

    func testBackupCommandIncludesIncrementalAndSafetyFlags() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/Volumes/Backup/Delta"))
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .fullVolume,
            sources: [BackupSource(path: "/")],
            repositoryID: repository.id
        )
        let command = try makeBuilder().backup(profile: profile, repository: repository)

        XCTAssertTrue(command.arguments.contains("backup"))
        XCTAssertTrue(command.arguments.contains("--json"))
        XCTAssertTrue(command.arguments.contains("--skip-if-unchanged"))
        XCTAssertTrue(command.arguments.contains("--one-file-system"))
        XCTAssertTrue(command.arguments.contains("--exclude"))
        XCTAssertTrue(command.arguments.contains("/Volumes/Backup/Delta"))
        XCTAssertTrue(command.arguments.contains("/"))
        XCTAssertTrue(command.environment["PATH"]?.hasPrefix("/usr/bin:") == true)
    }

    func testBackupCommandExcludesExpandedLocalHomeDestinationPath() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "  ~/DeltaBackups  "))
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: NSHomeDirectory())],
            repositoryID: repository.id
        )
        let expected = ("~/DeltaBackups" as NSString).expandingTildeInPath

        let command = try makeBuilder().backup(profile: profile, repository: repository)

        XCTAssertTrue(command.arguments.contains(expected))
        XCTAssertTrue(command.arguments.contains("\(expected)/**"))
        XCTAssertFalse(command.arguments.contains("~/DeltaBackups"))
    }

    func testBackupCommandIncludesCustomProfileExcludes() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id,
            excludePatterns: BackupExcludePatternParser.mergingDefaults(
                with: ["/Users/me/Downloads", "*.iso"]
            )
        )

        let command = try makeBuilder().backup(profile: profile, repository: repository)

        XCTAssertTrue(command.arguments.contains("/Users/me/Downloads"))
        XCTAssertTrue(command.arguments.contains("*.iso"))
    }

    func testRetentionCommandUsesSmartPresetArguments() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id,
            retention: RetentionPolicy(keepHourly: 24, keepDaily: 30, keepWeekly: 12, keepMonthly: 12, keepYearly: 2)
        )

        let command = try makeBuilder().forgetAndPrune(profile: profile, repository: repository)
        XCTAssertTrue(command.arguments.contains("forget"))
        XCTAssertTrue(command.arguments.contains("--keep-hourly"))
        XCTAssertTrue(command.arguments.contains("24"))
        XCTAssertTrue(command.arguments.contains("--keep-yearly"))
        XCTAssertTrue(command.arguments.contains("2"))
        XCTAssertTrue(command.arguments.contains("--prune"))
    }

    func testRestoreCommandSupportsSelectedFolderDryRun() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: "abc123",
            scope: .selectedPaths(["/Users/me/Documents"]),
            destination: .chosenFolder("/tmp/restore"),
            conflictPolicy: .never,
            verifyRestoredFiles: true,
            dryRun: true
        )

        let command = try makeBuilder().restore(request: request, repository: repository)
        XCTAssertTrue(command.arguments.contains("restore"))
        XCTAssertTrue(command.arguments.contains("--dry-run"))
        XCTAssertTrue(command.arguments.contains("--verbose=2"))
        XCTAssertFalse(command.arguments.contains("--verbose"))
        XCTAssertTrue(command.arguments.contains("--verify"))
        XCTAssertTrue(command.arguments.contains("--overwrite"))
        XCTAssertTrue(command.arguments.contains("never"))
        XCTAssertTrue(command.arguments.contains("/tmp/restore"))
        XCTAssertTrue(command.arguments.contains("abc123:/Users/me/Documents"))
    }

    func testListSnapshotEntriesCommandUsesResticJSONAndDirectoryFilter() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))

        let command = try makeBuilder().listSnapshotEntries(
            repository: repository,
            snapshotID: "abc123",
            directoryPath: "/Users/me/Documents"
        )

        XCTAssertEqual(
            Array(command.arguments.suffix(6)),
            ["ls", "--json", "--sort", "name", "abc123", "/Users/me/Documents"]
        )
    }

    func testS3RegionIsPassedAsResticBackendOption() throws {
        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "https://s3.example.com", bucket: "delta", path: nil, region: "ap-southeast-2")
        )

        let command = try makeBuilder().snapshots(repository: repository)

        XCTAssertTrue(command.arguments.contains("-o"))
        XCTAssertTrue(command.arguments.contains("s3.region=ap-southeast-2"))
    }

    func testRcloneCommandPinsBundledRcloneExecutableWhenAvailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-rclone-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let restic = directory.appendingPathComponent("restic")
        let rclone = directory.appendingPathComponent("rclone")
        FileManager.default.createFile(atPath: restic.path, contents: Data())
        FileManager.default.createFile(atPath: rclone.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rclone.path)

        let repository = BackupRepository(name: "Cloud", backend: .rclone(remote: "drive", path: "delta"))
        let builder = ResticCommandBuilder(
            resticExecutableURL: restic,
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge")
        )

        let command = try builder.snapshots(repository: repository)

        XCTAssertTrue(command.arguments.contains("-o"))
        XCTAssertTrue(command.arguments.contains("rclone.program=\(rclone.path)"))
    }

    func testCredentialEnvironmentIsLoadedFromKeychainReferences() throws {
        let secrets = InMemorySecretStore()
        let account = "aws-secret-\(UUID().uuidString)"
        try secrets.save(secret: "secret-value", account: account)

        let repository = BackupRepository(
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "bucket", path: nil, region: nil),
            credentialReferences: [
                RepositoryCredentialReference(environmentKey: "AWS_SECRET_ACCESS_KEY", keychainAccount: account)
            ]
        )
        let builder = ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge"),
            credentialResolver: secrets.resolver
        )

        let command = try builder.snapshots(repository: repository)
        XCTAssertEqual(command.environment["AWS_SECRET_ACCESS_KEY"], "secret-value")
    }

    func testCommandEnvironmentDoesNotInheritAmbientSecrets() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let builder = ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge"),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/me",
                "TMPDIR": "/tmp/me/",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "en_US.UTF-8",
                "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
                "AWS_SECRET_ACCESS_KEY": "ambient-secret",
                "SECRET_TOKEN": "ambient-token"
            ]
        )

        let command = try builder.snapshots(repository: repository)

        XCTAssertEqual(command.environment["HOME"], "/Users/me")
        XCTAssertEqual(command.environment["TMPDIR"], "/tmp/me/")
        XCTAssertEqual(command.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(command.environment["LC_CTYPE"], "en_US.UTF-8")
        XCTAssertEqual(command.environment["SSH_AUTH_SOCK"], "/tmp/ssh-agent.sock")
        XCTAssertEqual(command.environment["RESTIC_PROGRESS_FPS"], "1")
        XCTAssertEqual(command.environment["PATH"], "/Applications/Delta.app/Contents/MacOS:/usr/bin:/bin")
        XCTAssertNil(command.environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(command.environment["SECRET_TOKEN"])
    }

    func testCredentialUpdatePreservesBlankExistingValuesAndReplacesProvidedValues() throws {
        let secrets = InMemorySecretStore()
        let repositoryID = UUID()
        let resolver = secrets.resolver
        let existing = try resolver.saveCredentials(
            [
                "AWS_ACCESS_KEY_ID": "old-key",
                "AWS_SECRET_ACCESS_KEY": "old-secret"
            ],
            repositoryID: repositoryID
        )

        let updated = try resolver.updateCredentials(
            [
                "AWS_ACCESS_KEY_ID": "",
                "AWS_SECRET_ACCESS_KEY": " new-secret "
            ],
            existingReferences: existing,
            repositoryID: repositoryID,
            allowedKeys: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
        )
        let repository = BackupRepository(
            id: repositoryID,
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "bucket", path: nil, region: nil),
            credentialReferences: updated
        )

        let environment = try resolver.environment(for: repository)
        XCTAssertEqual(environment["AWS_ACCESS_KEY_ID"], "old-key")
        XCTAssertEqual(environment["AWS_SECRET_ACCESS_KEY"], " new-secret ")
        XCTAssertEqual(updated.count, 2)
    }

    func testCredentialUpdateDeletesReferencesNoLongerAllowedByBackend() throws {
        let secrets = InMemorySecretStore()
        let repositoryID = UUID()
        let resolver = secrets.resolver
        let existing = try resolver.saveCredentials(
            ["AWS_SECRET_ACCESS_KEY": "old-secret"],
            repositoryID: repositoryID
        )
        let oldReference = try XCTUnwrap(existing.first)

        let updated = try resolver.updateCredentials(
            [:],
            existingReferences: existing,
            repositoryID: repositoryID,
            allowedKeys: []
        )

        XCTAssertTrue(updated.isEmpty)
        XCTAssertThrowsError(try secrets.load(account: oldReference.keychainAccount))
    }

    func testCredentialTemplatesExposeDocumentedResticEnvironmentKeys() {
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .rest).contains("RESTIC_REST_USERNAME"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .rest).contains("RESTIC_REST_PASSWORD"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .s3).contains("AWS_SESSION_TOKEN"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .azureBlob).contains("AZURE_ACCOUNT_SAS"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .googleCloudStorage).contains("GOOGLE_ACCESS_TOKEN"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("ST_AUTH"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .rclone).contains("RCLONE_BWLIMIT"))
    }

    private func makeBuilder() -> ResticCommandBuilder {
        ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge")
        )
    }
}

private final class InMemorySecretStore: @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    var resolver: RepositoryCredentialResolver {
        RepositoryCredentialResolver(
            loadSecret: { account in
                try self.load(account: account)
            },
            saveSecret: { secret, account in
                try self.save(secret: secret, account: account)
            },
            deleteSecret: { account in
                try self.delete(account: account)
            }
        )
    }

    func save(secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = secret
    }

    func load(account: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[account] else {
            throw KeychainSecretError.unexpectedStatus(errSecItemNotFound)
        }
        return value
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}
