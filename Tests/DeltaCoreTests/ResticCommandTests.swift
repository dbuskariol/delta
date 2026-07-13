import XCTest
@testable import DeltaCore

final class ResticCommandTests: XCTestCase {
    func testRedactedDescriptionHidesPasswordCommandValue() {
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/restic"),
            arguments: [
                "-r", "rest:https://user:secret@example.com/repo",
                "--password-command", "'/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge' 'repository-secret-account'",
                "snapshots"
            ]
        )

        let description = command.redactedDescription

        XCTAssertTrue(description.contains("'-r' <redacted>"))
        XCTAssertTrue(description.contains("'--password-command' <redacted>"))
        XCTAssertFalse(description.contains("user:secret"))
        XCTAssertFalse(description.contains("DeltaSecretBridge"))
        XCTAssertFalse(description.contains("repository-secret-account"))
    }

    func testRedactedDescriptionHidesDestinationValuesFromLongAndInlineRepoOptions() {
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/restic"),
            arguments: [
                "--repo", "sftp://user:secret@example.com//srv/delta",
                "--repo=rest:https://user:secret@example.com/repo",
                "--repository-file", "/Users/me/.delta/repository-url",
                "--repository-file=/Users/me/.delta/repository-url",
                "snapshots"
            ]
        )

        let description = command.redactedDescription

        XCTAssertTrue(description.contains("'--repo' <redacted>"))
        XCTAssertTrue(description.contains("'--repository-file' <redacted>"))
        XCTAssertFalse(description.contains("user:secret"))
        XCTAssertFalse(description.contains("/Users/me/.delta/repository-url"))
        XCTAssertEqual(description.components(separatedBy: "<redacted>").count - 1, 4)
    }

    func testPasswordCommandCanUseMainAppBridgeMode() throws {
        let repository = BackupRepository(
            name: "Local",
            backend: .local(path: "/tmp/repo"),
            keychainAccount: "account"
        )
        let builder = ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/Delta"),
            secretBridgeArguments: ["--secret-bridge"]
        )

        let command = try builder.snapshots(repository: repository)

        XCTAssertEqual(command.arguments[2], "--password-command")
        XCTAssertEqual(
            command.arguments[3],
            "'/Applications/Delta.app/Contents/MacOS/Delta' '--secret-bridge' 'account'"
        )
    }

    func testPasswordRotationCommandsKeepNewPasswordOutOfArgumentsEnvironmentAndLogs() throws {
        let repository = BackupRepository(
            name: "Local",
            backend: .local(path: "/tmp/repo"),
            keychainAccount: "account"
        )
        let builder = makeBuilder()
        let password = "correct horse battery staple"

        let command = try builder.addRepositoryKey(repository: repository, password: password)

        XCTAssertTrue(command.arguments.contains("--new-password-file"))
        XCTAssertTrue(command.arguments.contains("/dev/stdin"))
        XCTAssertFalse(command.arguments.contains { $0.contains(password) })
        XCTAssertFalse(command.environment.values.contains { $0.contains(password) })
        XCTAssertFalse(command.redactedDescription.contains(password))
        XCTAssertEqual(command.sensitiveStandardInput, Data("\(password)\n".utf8))
    }

    func testReconnectCommandUsesStandardInputInsteadOfPasswordBridge() throws {
        let repository = BackupRepository(
            name: "Local",
            backend: .local(path: "/tmp/repo"),
            keychainAccount: "account"
        )

        let command = try makeBuilder().validateRepositoryPassword(
            repository: repository,
            password: "original-password"
        )

        XCTAssertTrue(command.arguments.contains("--password-file"))
        XCTAssertTrue(command.arguments.contains("/dev/stdin"))
        XCTAssertFalse(command.arguments.contains("--password-command"))
        XCTAssertFalse(command.redactedDescription.contains("original-password"))
    }

    func testBackendURLBuilderSupportsPrimaryBackends() throws {
        let builder = ResticBackendURLBuilder()

        XCTAssertEqual(try builder.repositoryURL(for: .local(path: "/Volumes/Backup/Delta")), "/Volumes/Backup/Delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "nas.local", path: "/tank/delta", username: "me", port: nil, identityFilePath: nil)), "sftp:me@nas.local:/tank/delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "nas.local", path: "/tank/delta", username: "me", port: 2222, identityFilePath: nil)), "sftp://me@nas.local:2222//tank/delta")
        XCTAssertEqual(try builder.repositoryURL(for: .sftp(host: "::1", path: "/srv/restic-repo", username: "user", port: 2222, identityFilePath: nil)), "sftp://user@[::1]:2222//srv/restic-repo")
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
        XCTAssertTrue(command.arguments.contains("--json"))
        XCTAssertTrue(command.arguments.contains("--keep-hourly"))
        XCTAssertTrue(command.arguments.contains("24"))
        XCTAssertTrue(command.arguments.contains("--keep-yearly"))
        XCTAssertTrue(command.arguments.contains("2"))
        XCTAssertTrue(command.arguments.contains("--prune"))
    }

    func testBackupCommandIgnoresNonPositiveBandwidthLimits() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let profile = BackupProfile(
            name: "Mac",
            sourceMode: .customFolders,
            sources: [BackupSource(path: "/Users/me/Documents")],
            repositoryID: repository.id,
            schedule: BackupSchedule(uploadLimitKiB: 0, downloadLimitKiB: -20)
        )

        let command = try makeBuilder().backup(profile: profile, repository: repository)

        XCTAssertFalse(command.arguments.contains("--limit-upload"))
        XCTAssertFalse(command.arguments.contains("--limit-download"))
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
        XCTAssertFalse(command.arguments.contains("--verify"))
        XCTAssertTrue(command.arguments.contains("--overwrite"))
        XCTAssertTrue(command.arguments.contains("never"))
        XCTAssertTrue(command.arguments.contains("/tmp/restore"))
        XCTAssertTrue(command.arguments.contains("abc123"))
        XCTAssertFalse(command.arguments.contains("abc123:/Users/me/Documents"))
        XCTAssertEqual(includeArguments(in: command.arguments), ["/Users/me/Documents"])
    }

    func testRestoreCommandVerifiesOnlyRealRestores() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: "abc123",
            destination: .chosenFolder("/tmp/restore"),
            verifyRestoredFiles: true,
            dryRun: false
        )

        let command = try makeBuilder().restore(request: request, repository: repository)

        XCTAssertTrue(command.arguments.contains("--verify"))
        XCTAssertFalse(command.arguments.contains("--dry-run"))
    }

    func testRestoreCommandNormalizesSelectedPathsAndTarget() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let target = "~/Delta Restore"
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: " abc123 ",
            scope: .selectedPaths([
                " /Users/me/Documents/ ",
                "/Users/me/Documents/Nested/",
                "/Users/me/Desktop/"
            ]),
            destination: .chosenFolder(" \(target) "),
            dryRun: true
        )

        let command = try makeBuilder().restore(request: request, repository: repository)
        let includeValues = includeArguments(in: command.arguments)

        XCTAssertEqual(includeValues, ["/Users/me/Desktop", "/Users/me/Documents"])
        XCTAssertFalse(includeValues.contains("/Users/me/Documents/Nested"))
        XCTAssertTrue(command.arguments.contains((target as NSString).expandingTildeInPath))
        XCTAssertEqual(command.arguments.last, "abc123")
    }

    func testRestoreCommandRejectsBlankRestoreTarget() {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: "abc123",
            destination: .chosenFolder("   ")
        )

        XCTAssertThrowsError(try makeBuilder().restore(request: request, repository: repository)) { error in
            XCTAssertEqual(error as? ResticCommandValidationError, .missingRestoreTarget)
        }
    }

    func testRestoreCommandRejectsRelativeSelectedPath() {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: "abc123",
            scope: .selectedPaths(["Users/me/Documents"]),
            destination: .chosenFolder("/tmp/restore")
        )

        XCTAssertThrowsError(try makeBuilder().restore(request: request, repository: repository)) { error in
            XCTAssertEqual(error as? ResticCommandValidationError, .invalidRestorePath("Users/me/Documents"))
        }
    }

    func testRestoreCommandRejectsBlankSnapshotID() {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))
        let request = RestoreRequest(
            repositoryID: repository.id,
            snapshotID: " ",
            destination: .chosenFolder("/tmp/restore")
        )

        XCTAssertThrowsError(try makeBuilder().restore(request: request, repository: repository)) { error in
            XCTAssertEqual(error as? ResticCommandValidationError, .missingSnapshotID)
        }
    }

    func testListSnapshotEntriesCommandUsesResticJSONAndDirectoryFilter() throws {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))

        let command = try makeBuilder().listSnapshotEntries(
            repository: repository,
            snapshotID: " abc123 ",
            directoryPath: " /Users/me/Documents/ "
        )

        XCTAssertEqual(
            Array(command.arguments.suffix(6)),
            ["ls", "--json", "--sort", "name", "abc123", "/Users/me/Documents"]
        )
    }

    func testListSnapshotEntriesRejectsBlankSnapshotID() {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))

        XCTAssertThrowsError(
            try makeBuilder().listSnapshotEntries(
                repository: repository,
                snapshotID: " ",
                directoryPath: "/Users/me/Documents"
            )
        ) { error in
            XCTAssertEqual(error as? ResticCommandValidationError, .missingSnapshotID)
        }
    }

    func testListSnapshotEntriesRejectsRelativeDirectoryFilter() {
        let repository = BackupRepository(name: "Local", backend: .local(path: "/repo"))

        XCTAssertThrowsError(
            try makeBuilder().listSnapshotEntries(
                repository: repository,
                snapshotID: "abc123",
                directoryPath: "Users/me/Documents"
            )
        ) { error in
            XCTAssertEqual(error as? ResticCommandValidationError, .invalidSnapshotBrowsePath("Users/me/Documents"))
        }
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

    func testSFTPCommandUsesNonInteractiveSSHOptions() throws {
        let repository = BackupRepository(
            name: "SFTP",
            backend: .sftp(host: "nas.local", path: "/tank/delta", username: "me", port: nil, identityFilePath: nil)
        )

        let command = try makeBuilder().snapshots(repository: repository)
        let optionValue = try XCTUnwrap(optionValues(in: command.arguments).first { $0.hasPrefix("sftp.args=") })

        XCTAssertTrue(optionValue.contains("BatchMode=yes"))
        XCTAssertTrue(optionValue.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(optionValue.contains("ServerAliveInterval=60"))
        XCTAssertTrue(optionValue.contains("ServerAliveCountMax=240"))
        XCTAssertFalse(optionValue.contains("-i "))
    }

    func testSFTPCommandPassesConfiguredIdentityFile() throws {
        let repository = BackupRepository(
            name: "SFTP",
            backend: .sftp(
                host: "nas.local",
                path: "/tank/delta",
                username: "me",
                port: nil,
                identityFilePath: "/Users/me/.ssh/delta backup"
            )
        )

        let command = try makeBuilder().snapshots(repository: repository)
        let optionValue = try XCTUnwrap(optionValues(in: command.arguments).first { $0.hasPrefix("sftp.args=") })

        XCTAssertTrue(optionValue.contains("-i '/Users/me/.ssh/delta backup'"))
        XCTAssertTrue(optionValue.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(optionValue.contains("BatchMode=yes"))
    }

    func testSFTPCommandCanPinKnownHostsFileForNonInteractiveAcceptance() throws {
        let repository = BackupRepository(
            name: "SFTP",
            backend: .sftp(
                host: "nas.local",
                path: "/tank/delta",
                username: "me",
                port: nil,
                identityFilePath: nil
            )
        )
        let builder = ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/Delta"),
            baseEnvironment: [
                "DELTA_SFTP_KNOWN_HOSTS_FILE": "/tmp/delta known_hosts",
                "PATH": "/usr/bin:/bin"
            ]
        )

        let command = try builder.snapshots(repository: repository)
        let optionValue = try XCTUnwrap(optionValues(in: command.arguments).first { $0.hasPrefix("sftp.args=") })

        XCTAssertTrue(optionValue.contains("'UserKnownHostsFile=/tmp/delta known_hosts'"))
        XCTAssertTrue(optionValue.contains("BatchMode=yes"))
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

    func testCredentialSaveRollsBackEarlierSecretsWhenLaterSaveFails() throws {
        enum TestError: Error {
            case saveFailed
        }

        let repositoryID = UUID()
        let firstAccount = "repository-\(repositoryID.uuidString)-env-A_KEY"
        let recorder = CredentialRollbackRecorder(failingSuffix: "B_FAIL")
        let resolver = RepositoryCredentialResolver(
            loadSecret: { _ in "" },
            saveSecret: { _, account in
                try recorder.save(account: account, error: TestError.saveFailed)
            },
            deleteSecret: { account in
                recorder.delete(account: account)
            }
        )

        XCTAssertThrowsError(
            try resolver.saveCredentials(
                [
                    "A_KEY": "first",
                    "B_FAIL": "second"
                ],
                repositoryID: repositoryID
            )
        )
        XCTAssertTrue(recorder.savedAccounts.isEmpty)
        XCTAssertEqual(recorder.deletedAccounts, [firstAccount])
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

    func testCredentialUpdateRestoresEarlierExistingSecretWhenLaterSaveFails() throws {
        enum TestError: Error {
            case saveFailed
        }

        let secrets = InMemorySecretStore()
        let repositoryID = UUID()
        let existing = try secrets.resolver.saveCredentials(
            [
                "A_KEY": "old-a",
                "B_FAIL": "old-b"
            ],
            repositoryID: repositoryID
        )
        let resolver = RepositoryCredentialResolver(
            loadSecret: { account in
                try secrets.load(account: account)
            },
            saveSecret: { secret, account in
                if account.hasSuffix("B_FAIL") {
                    throw TestError.saveFailed
                }
                try secrets.save(secret: secret, account: account)
            },
            deleteSecret: { account in
                try secrets.delete(account: account)
            }
        )

        XCTAssertThrowsError(
            try resolver.updateCredentials(
                [
                    "A_KEY": "new-a",
                    "B_FAIL": "new-b"
                ],
                existingReferences: existing,
                repositoryID: repositoryID,
                allowedKeys: ["A_KEY", "B_FAIL"]
            )
        )

        let repository = BackupRepository(
            id: repositoryID,
            name: "S3",
            backend: .s3(endpoint: "s3.amazonaws.com", bucket: "bucket", path: nil, region: nil),
            credentialReferences: existing
        )
        let environment = try secrets.resolver.environment(for: repository)
        XCTAssertEqual(environment["A_KEY"], "old-a")
        XCTAssertEqual(environment["B_FAIL"], "old-b")
    }

    func testCredentialUpdateDeletesEarlierNewSecretWhenLaterSaveFails() throws {
        enum TestError: Error {
            case saveFailed
        }

        let secrets = InMemorySecretStore()
        let repositoryID = UUID()
        let existing = try secrets.resolver.saveCredentials(
            ["A_KEY": "old-a"],
            repositoryID: repositoryID
        )
        let newAccount = "repository-\(repositoryID.uuidString)-env-B_KEY"
        let resolver = RepositoryCredentialResolver(
            loadSecret: { account in
                try secrets.load(account: account)
            },
            saveSecret: { secret, account in
                if account.hasSuffix("C_FAIL") {
                    throw TestError.saveFailed
                }
                try secrets.save(secret: secret, account: account)
            },
            deleteSecret: { account in
                try secrets.delete(account: account)
            }
        )

        XCTAssertThrowsError(
            try resolver.updateCredentials(
                [
                    "B_KEY": "new-b",
                    "C_FAIL": "new-c"
                ],
                existingReferences: existing,
                repositoryID: repositoryID,
                allowedKeys: ["A_KEY", "B_KEY", "C_FAIL"]
            )
        )

        XCTAssertThrowsError(try secrets.load(account: newAccount))
        let originalReference = try XCTUnwrap(existing.first)
        XCTAssertEqual(try secrets.load(account: originalReference.keychainAccount), "old-a")
    }

    func testCredentialTemplatesExposeDocumentedResticEnvironmentKeys() {
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .rest).contains("RESTIC_REST_USERNAME"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .rest).contains("RESTIC_REST_PASSWORD"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .s3).contains("AWS_SESSION_TOKEN"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .azureBlob).contains("AZURE_ACCOUNT_SAS"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .googleCloudStorage).contains("GOOGLE_ACCESS_TOKEN"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("ST_AUTH"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("OS_USER_ID"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("OS_USER_DOMAIN_ID"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("OS_PROJECT_DOMAIN_ID"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("OS_TRUST_ID"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("OS_APPLICATION_CREDENTIAL_NAME"))
        XCTAssertTrue(ResticBackendCredentialTemplates.keys(for: .swiftObjectStorage).contains("SWIFT_DEFAULT_CONTAINER_POLICY"))
        XCTAssertEqual(ResticBackendCredentialTemplates.keys(for: .rclone), ["RCLONE_CONFIG"])
    }

    func testCredentialTemplatesSeparateSecretAndNonSecretFields() throws {
        let restFields = ResticBackendCredentialTemplates.fields(for: .rest)
        let restUsername = try XCTUnwrap(restFields.first { $0.environmentKey == "RESTIC_REST_USERNAME" })
        let restPassword = try XCTUnwrap(restFields.first { $0.environmentKey == "RESTIC_REST_PASSWORD" })
        XCTAssertEqual(restUsername.title, "Username")
        XCTAssertFalse(restUsername.isSecret)
        XCTAssertEqual(restPassword.title, "Password")
        XCTAssertTrue(restPassword.isSecret)

        let rcloneConfig = try XCTUnwrap(ResticBackendCredentialTemplates.fields(for: .rclone).first)
        XCTAssertEqual(rcloneConfig.environmentKey, "RCLONE_CONFIG")
        XCTAssertEqual(rcloneConfig.title, "Config File")
        XCTAssertFalse(rcloneConfig.isSecret)
    }

    private func makeBuilder() -> ResticCommandBuilder {
        ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
            secretBridgeURL: URL(fileURLWithPath: "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge")
        )
    }

    private func includeArguments(in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == "--include", arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    private func optionValues(in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == "-o", arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
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
            throw KeychainSecretError.itemNotFound
        }
        return value
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

private final class CredentialRollbackRecorder: @unchecked Sendable {
    private let failingSuffix: String
    private var saved: Set<String> = []
    private var deleted: Set<String> = []
    private let lock = NSLock()

    init(failingSuffix: String) {
        self.failingSuffix = failingSuffix
    }

    var savedAccounts: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    var deletedAccounts: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return deleted
    }

    func save(account: String, error: Error) throws {
        lock.lock()
        defer { lock.unlock() }
        if account.hasSuffix(failingSuffix) {
            throw error
        }
        saved.insert(account)
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        deleted.insert(account)
        saved.remove(account)
    }
}
