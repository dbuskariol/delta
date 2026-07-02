import DeltaCore
import Foundation

enum AcceptanceExternalLifecycleCommand {
    static func run(
        executableURL: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let kind = try AcceptanceExternalKind(environmentValue: environment["DELTA_EXTERNAL_ACCEPTANCE_KIND"])
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("delta-external-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appSupport = try AppDirectories.applicationSupportDirectory(fileManager: fileManager)
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let documentsURL = sourceURL.appendingPathComponent("Documents", isDirectory: true)
        let photosURL = sourceURL.appendingPathComponent("Photos", isDirectory: true)
        let fullRestoreURL = root.appendingPathComponent("restore-full", isDirectory: true)
        let selectedRestoreURL = root.appendingPathComponent("restore-selected", isDirectory: true)
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosURL, withIntermediateDirectories: true)

        let reportURL = documentsURL.appendingPathComponent("report.txt")
        let imageURL = photosURL.appendingPathComponent("image.txt")
        let rootMarkerURL = sourceURL.appendingPathComponent("root.txt")
        try "External lifecycle validation\n".write(to: reportURL, atomically: true, encoding: .utf8)
        try "image-bytes-\(timestamp)\n".write(to: imageURL, atomically: true, encoding: .utf8)
        try "root marker\n".write(to: rootMarkerURL, atomically: true, encoding: .utf8)

        let database = try DeltaDatabase.live()
        let repositoryID = UUID()
        let profileID = UUID()
        let secretStore = KeychainSecretStore()
        let credentialResolver = RepositoryCredentialResolver(
            secretStore: secretStore,
            authenticationPolicy: .failIfInteractionNeeded
        )
        let keychainAccount = "external-lifecycle-\(repositoryID.uuidString)"
        var cleanupAccounts = [keychainAccount]
        defer {
            for account in cleanupAccounts {
                try? secretStore.delete(account: account)
            }
        }

        try secretStore.save(
            secret: UUID().uuidString + UUID().uuidString,
            account: keychainAccount,
            authenticationPolicy: .failIfInteractionNeeded
        )

        let backend = try kind.backend(environment: environment)
        let credentialReferences = try credentialResolver.saveCredentials(
            try kind.credentials(environment: environment),
            repositoryID: repositoryID
        )
        cleanupAccounts += credentialReferences.map(\.keychainAccount)

        let repository = BackupRepository(
            id: repositoryID,
            name: "External \(kind.displayName) Lifecycle",
            backend: backend,
            keychainAccount: keychainAccount,
            credentialReferences: credentialReferences
        )
        let profile = BackupProfile(
            id: profileID,
            name: "External \(kind.displayName) Lifecycle",
            sourceMode: .customFolders,
            sources: [BackupSource(path: sourceURL.path)],
            repositoryID: repositoryID,
            schedule: BackupSchedule(kind: .hourly(minute: 0), isEnabled: false),
            retention: RetentionPolicy(
                keepHourly: 1,
                keepDaily: 0,
                keepWeekly: 0,
                keepMonthly: 0,
                keepYearly: 0,
                pruneAfterForget: true,
                checkAfterPrune: true
            )
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        let resticURL = ResticExecutableLocator().locate(in: bundle)
        let commandBuilder = ResticCommandBuilder(
            resticExecutableURL: resticURL,
            secretBridgeURL: executableURL,
            secretBridgeArguments: ["--secret-bridge"],
            credentialResolver: credentialResolver
        )
        let coordinator = BackupCoordinator(
            database: database,
            commandBuilder: commandBuilder
        )

        let missingCredentialProbe = try runMissingCredentialProbeIfNeeded(
            kind: kind,
            environment: environment,
            repository: repository,
            keychainAccount: keychainAccount,
            commandBuilder: commandBuilder
        )
        let badTargetProbe = try runBadTargetProbeIfNeeded(
            kind: kind,
            environment: environment,
            repositoryID: repositoryID,
            keychainAccount: keychainAccount,
            database: database,
            commandBuilder: commandBuilder
        )

        let firstRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(firstRun.status == .succeeded || firstRun.status == .warning, "First backup did not complete: \(firstRun.message ?? firstRun.status.displayName)")
        try require(try preparedRunCount(database: database, repositoryID: repositoryID) == 1, "Automatic destination preparation did not run exactly once before the first backup.")

        let noChangeRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(noChangeRun.status == .succeeded || noChangeRun.status == .warning, "No-change backup did not complete: \(noChangeRun.message ?? noChangeRun.status.displayName)")
        try require(try preparedRunCount(database: database, repositoryID: repositoryID) == 1, "Prepared destination was unexpectedly initialized again on reuse.")
        let noChangeSummary = try requireValue(noChangeRun.backupSummary, "No-change backup summary was missing.")
        try require(noChangeSummary.filesNew == 0, "No-change backup reported \(noChangeSummary.filesNew) new files.")
        try require(noChangeSummary.filesChanged == 0, "No-change backup reported \(noChangeSummary.filesChanged) changed files.")
        try require((noChangeSummary.dataBlobs ?? 0) == 0, "No-change backup reported new file data.")

        try "External lifecycle validation updated\n".write(to: reportURL, atomically: true, encoding: .utf8)
        let incrementalRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(incrementalRun.status == .succeeded || incrementalRun.status == .warning, "Incremental backup did not complete: \(incrementalRun.message ?? incrementalRun.status.displayName)")
        let incrementalSummary = try requireValue(incrementalRun.backupSummary, "Incremental backup summary was missing.")
        try require(incrementalSummary.filesChanged > 0 || (incrementalSummary.dataBlobs ?? 0) > 0, "Incremental backup did not report changed file data.")

        let snapshots = try database.fetchSnapshots(repositoryID: repositoryID)
        try require(snapshots.count >= 2, "Expected at least two restore points after incremental backup, found \(snapshots.count).")
        let latestSnapshot = try requireValue(snapshots.max(by: { $0.time < $1.time }), "No restore point was cached.")

        let rootEntries = try coordinator.listSnapshotEntries(
            repository: repository,
            snapshotID: latestSnapshot.id,
            directoryPath: sourceURL.path
        )
        try require(rootEntries.contains { $0.path == documentsURL.path && $0.type == .directory }, "Restore browser did not list Documents directory.")
        try require(rootEntries.contains { $0.path == photosURL.path && $0.type == .directory }, "Restore browser did not list Photos directory.")
        try require(rootEntries.contains { $0.path == rootMarkerURL.path && $0.type == .file }, "Restore browser did not list root marker file.")

        let fullRestore = try coordinator.restore(
            request: RestoreRequest(
                repositoryID: repositoryID,
                snapshotID: latestSnapshot.id,
                destination: .chosenFolder(fullRestoreURL.path),
                dryRun: false
            ),
            repository: repository
        )
        try require(fullRestore.status == .succeeded || fullRestore.status == .warning, "Full restore did not complete: \(fullRestore.message ?? fullRestore.status.displayName)")
        try require(try contentsOfFirstFile(named: "report.txt", under: fullRestoreURL)?.contains("updated") == true, "Full restore did not recover updated report.txt.")
        try require(try contentsOfFirstFile(named: "image.txt", under: fullRestoreURL)?.contains("image-bytes") == true, "Full restore did not recover image.txt.")

        let selectedFolderRestore = try coordinator.restore(
            request: RestoreRequest(
                repositoryID: repositoryID,
                snapshotID: latestSnapshot.id,
                scope: .selectedPaths([documentsURL.path]),
                destination: .chosenFolder(selectedRestoreURL.path),
                dryRun: false
            ),
            repository: repository
        )
        try require(selectedFolderRestore.status == .succeeded || selectedFolderRestore.status == .warning, "Selected folder restore did not complete: \(selectedFolderRestore.message ?? selectedFolderRestore.status.displayName)")
        try require(try contentsOfFirstFile(named: "report.txt", under: selectedRestoreURL)?.contains("updated") == true, "Selected folder restore did not recover report.txt.")
        try require(try firstFile(named: "image.txt", under: selectedRestoreURL) == nil, "Selected folder restore unexpectedly recovered image.txt.")

        let checkRun = try coordinator.check(repository: repository, readDataSubset: "1/100")
        try require(checkRun.status == .succeeded || checkRun.status == .warning, "Destination check did not complete: \(checkRun.message ?? checkRun.status.displayName)")

        let maintenanceRuns = try coordinator.runRetentionMaintenance(profile: profile, repository: repository)
        try require(maintenanceRuns.contains { $0.kind == .prune && ($0.status == .succeeded || $0.status == .warning) }, "Cleanup did not complete successfully.")
        try require(maintenanceRuns.contains { $0.kind == .check && ($0.status == .succeeded || $0.status == .warning) }, "Post-cleanup check did not run successfully.")

        let latestJobs = try database.fetchJobRuns(limit: 80)
        let backupCount = latestJobs.filter { $0.repositoryID == repositoryID && $0.kind == .backup }.count
        let restoreCount = latestJobs.filter { $0.repositoryID == repositoryID && $0.kind == .restore }.count

        return """
        # Delta Installed External Lifecycle Acceptance

        - Generated: \(timestamp)
        - Kind: \(kind.rawValue)
        - App: \(bundle.bundleURL.path)
        - Executable: \(executableURL.path)
        - Application Support: \(appSupport.path)
        - Restic: \(resticURL.path)
        - Destination type: \(repository.backend.kind.displayName)
        - Keychain credential references: \(credentialReferences.count)

        This verifies the installed Delta app's own coordinator against a configured external destination. It uses Delta's SQLite store, Keychain password command, bundled restic, automatic destination preparation, restore-point cache, restore browser listing, restore command construction, destination checks, and retention cleanup.

        ## Result

        Installed external \(kind.rawValue) lifecycle acceptance passed.

        - Delta coordinator lifecycle: Yes
        - Automatic destination preparation runs: 1
        - Missing credential probe: \(missingCredentialProbe)
        - Wrong SFTP credential or target probe: \(badTargetProbe)
        - First backup status: \(firstRun.status.displayName)
        - No-change backup: \(noChangeSummary.conciseText)
        - Incremental backup: \(incrementalSummary.detailedText)
        - Cached restore points: \(snapshots.count)
        - Latest restore point: \(latestSnapshot.id)
        - Restore browser entries verified: \(rootEntries.count)
        - Full restore status: \(fullRestore.status.displayName)
        - Selected folder restore status: \(selectedFolderRestore.status.displayName)
        - Destination check status: \(checkRun.status.displayName)
        - Cleanup runs: \(maintenanceRuns.map { $0.kind.displayName + " " + $0.status.displayName }.joined(separator: ", "))
        - Stored backup jobs: \(backupCount)
        - Stored restore jobs: \(restoreCount)
        - Keychain items deleted on exit: Yes
        """
    }

    private static func runMissingCredentialProbeIfNeeded(
        kind: AcceptanceExternalKind,
        environment: [String: String],
        repository: BackupRepository,
        keychainAccount: String,
        commandBuilder: ResticCommandBuilder
    ) throws -> String {
        guard kind == .s3, environment["DELTA_EXTERNAL_ACCEPTANCE_REQUIRE_MISSING_CREDENTIAL_PROBE"] == "1" else {
            return "Not configured"
        }
        var probeRepository = repository
        probeRepository.id = UUID()
        probeRepository.keychainAccount = keychainAccount
        probeRepository.credentialReferences = []

        let result = try ResticRunner().run(try commandBuilder.snapshots(repository: probeRepository))
        if result.status == .succeeded || result.status == .warning {
            throw AcceptanceExternalLifecycleError.validationFailed("Missing S3 credential probe unexpectedly succeeded.")
        }
        guard result.failureKind == .missingBackendCredentials else {
            throw AcceptanceExternalLifecycleError.validationFailed(
                "Missing S3 credential probe failed as \(result.failureKind?.rawValue ?? "unclassified"), expected missingBackendCredentials."
            )
        }
        return "Passed"
    }

    private static func runBadTargetProbeIfNeeded(
        kind: AcceptanceExternalKind,
        environment: [String: String],
        repositoryID: UUID,
        keychainAccount: String,
        database: DeltaDatabase,
        commandBuilder: ResticCommandBuilder
    ) throws -> String {
        guard kind == .sftp, let badRepository = environment["DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY"], !badRepository.isEmpty else {
            return "Not configured"
        }
        let badBackend = try AcceptanceExternalKind.sftp.sftpBackend(
            repository: badRepository,
            identityFilePath: environment["DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY"]
        )
        let probeRepository = BackupRepository(
            id: UUID(),
            name: "External SFTP Failure Probe",
            backend: badBackend,
            keychainAccount: keychainAccount
        )
        let coordinator = BackupCoordinator(database: database, commandBuilder: commandBuilder)
        do {
            _ = try coordinator.refreshSnapshots(repository: probeRepository)
            throw AcceptanceExternalLifecycleError.validationFailed("Wrong SFTP credential or target probe unexpectedly succeeded for repository \(repositoryID).")
        } catch AcceptanceExternalLifecycleError.validationFailed {
            throw AcceptanceExternalLifecycleError.validationFailed("Wrong SFTP credential or target probe unexpectedly succeeded.")
        } catch {
            return "Passed"
        }
    }

    private static func preparedRunCount(database: DeltaDatabase, repositoryID: UUID) throws -> Int {
        try database.fetchJobRuns(limit: 100)
            .filter { $0.repositoryID == repositoryID && $0.kind == .initializeRepository && ($0.status == .succeeded || $0.status == .warning) }
            .count
    }

    fileprivate static func requiredEnvironment(_ key: String, environment: [String: String]) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AcceptanceExternalLifecycleError.validationFailed("\(key) is required.")
        }
        return value
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw AcceptanceExternalLifecycleError.validationFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw AcceptanceExternalLifecycleError.validationFailed(message)
        }
        return value
    }

    private static func contentsOfFirstFile(named name: String, under root: URL) throws -> String? {
        guard let file = try firstFile(named: name, under: root) else {
            return nil
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private static func firstFile(named name: String, under root: URL) throws -> URL? {
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

private enum AcceptanceExternalKind: String {
    case mounted
    case sftp
    case rest
    case s3
    case b2
    case azure
    case gcs
    case swift
    case rclone
    case custom

    init(environmentValue: String?) throws {
        guard
            let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            let kind = AcceptanceExternalKind(rawValue: value)
        else {
            throw AcceptanceExternalLifecycleError.validationFailed("DELTA_EXTERNAL_ACCEPTANCE_KIND must be mounted, sftp, rest, s3, b2, azure, gcs, swift, rclone, or custom.")
        }
        self = kind
    }

    var displayName: String {
        switch self {
        case .mounted: "Mounted"
        case .sftp: "SFTP"
        case .rest: "REST"
        case .s3: "S3"
        case .b2: "Backblaze B2"
        case .azure: "Azure Blob"
        case .gcs: "Google Cloud Storage"
        case .swift: "OpenStack Swift"
        case .rclone: "rclone"
        case .custom: "Custom"
        }
    }

    func backend(environment: [String: String]) throws -> RepositoryBackend {
        switch self {
        case .mounted:
            let path = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH",
                environment: environment
            )
            guard path.hasPrefix("/Volumes/") else {
                throw AcceptanceExternalLifecycleError.validationFailed("Mounted acceptance repository must live under /Volumes.")
            }
            return .local(path: path)
        case .sftp:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_SFTP_REPOSITORY",
                environment: environment
            )
            return try sftpBackend(
                repository: repository,
                identityFilePath: environment["DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY"]
            )
        case .rest:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_REST_REPOSITORY",
                environment: environment
            )
            return try restBackend(repository: repository)
        case .s3:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_S3_REPOSITORY",
                environment: environment
            )
            return try s3Backend(
                repository: repository,
                region: environment["AWS_DEFAULT_REGION"]
            )
        case .b2:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_B2_REPOSITORY",
                environment: environment
            )
            return try b2Backend(repository: repository)
        case .azure:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_AZURE_REPOSITORY",
                environment: environment
            )
            return try azureBackend(repository: repository)
        case .gcs:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_GCS_REPOSITORY",
                environment: environment
            )
            return try gcsBackend(repository: repository)
        case .swift:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_SWIFT_REPOSITORY",
                environment: environment
            )
            return try swiftBackend(repository: repository)
        case .rclone:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_RCLONE_REPOSITORY",
                environment: environment
            )
            return try rcloneBackend(repository: repository)
        case .custom:
            let repository = try AcceptanceExternalLifecycleCommand.requiredEnvironment(
                "DELTA_ACCEPTANCE_CUSTOM_REPOSITORY",
                environment: environment
            )
            return .custom(repository: repository)
        }
    }

    func credentials(environment: [String: String]) throws -> [String: String] {
        switch self {
        case .mounted, .sftp:
            return [:]
        case .rest:
            return credentials(for: .rest, environment: environment)
        case .s3:
            _ = try requiredCredential("AWS_ACCESS_KEY_ID", environment: environment)
            _ = try requiredCredential("AWS_SECRET_ACCESS_KEY", environment: environment)
            return credentials(for: .s3, environment: environment)
        case .b2:
            _ = try requiredCredential("B2_ACCOUNT_ID", environment: environment)
            _ = try requiredCredential("B2_ACCOUNT_KEY", environment: environment)
            return credentials(for: .backblazeB2, environment: environment)
        case .azure:
            _ = try requiredCredential("AZURE_ACCOUNT_NAME", environment: environment)
            try requireAnyCredential(["AZURE_ACCOUNT_KEY", "AZURE_ACCOUNT_SAS"], environment: environment)
            return credentials(for: .azureBlob, environment: environment)
        case .gcs:
            try requireAnyCredential(["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_ACCESS_TOKEN"], environment: environment)
            if let credentialsPath = optionalCredential("GOOGLE_APPLICATION_CREDENTIALS", environment: environment),
               !FileManager.default.isReadableFile(atPath: credentialsPath) {
                throw AcceptanceExternalLifecycleError.validationFailed("GOOGLE_APPLICATION_CREDENTIALS is not readable: \(credentialsPath)")
            }
            return credentials(for: .googleCloudStorage, environment: environment)
        case .swift:
            let values = credentials(for: .swiftObjectStorage, environment: environment)
            let hasLegacyV1 = hasAll(["ST_AUTH", "ST_USER", "ST_KEY"], in: values)
            let hasPreauthenticatedStorageURL = hasAll(["OS_STORAGE_URL", "OS_AUTH_TOKEN"], in: values)
            let hasPasswordAuth = values["OS_AUTH_URL"] != nil
                && (values["OS_USERNAME"] != nil || values["OS_USER_ID"] != nil)
                && values["OS_PASSWORD"] != nil
            let hasApplicationCredentialAuth = values["OS_AUTH_URL"] != nil
                && (values["OS_APPLICATION_CREDENTIAL_ID"] != nil || values["OS_APPLICATION_CREDENTIAL_NAME"] != nil)
                && values["OS_APPLICATION_CREDENTIAL_SECRET"] != nil
            guard hasLegacyV1 || hasPreauthenticatedStorageURL || hasPasswordAuth || hasApplicationCredentialAuth else {
                throw AcceptanceExternalLifecycleError.validationFailed("OpenStack Swift acceptance requires ST_AUTH/ST_USER/ST_KEY, OS_STORAGE_URL/OS_AUTH_TOKEN, Keystone password auth, or Keystone application credential auth.")
            }
            return values
        case .rclone:
            let configPath = try requiredCredential("RCLONE_CONFIG", environment: environment)
            if !FileManager.default.isReadableFile(atPath: configPath) {
                throw AcceptanceExternalLifecycleError.validationFailed("RCLONE_CONFIG is not readable: \(configPath)")
            }
            return credentials(for: .rclone, environment: environment)
        case .custom:
            return try customCredentials(environment: environment)
        }
    }

    fileprivate func sftpBackend(repository: String, identityFilePath: String?) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sftp:") else {
            throw AcceptanceExternalLifecycleError.validationFailed("SFTP acceptance repository must start with sftp:.")
        }
        if trimmed.hasPrefix("sftp://") {
            guard let components = URLComponents(string: trimmed), let host = components.host else {
                throw AcceptanceExternalLifecycleError.validationFailed("Invalid SFTP URL: \(trimmed)")
            }
            let path = normalizedSFTPPath(components.path)
            return .sftp(
                host: host,
                path: path,
                username: components.user,
                port: components.port,
                identityFilePath: identityFilePath
            )
        }

        let remainder = String(trimmed.dropFirst("sftp:".count))
        guard let separator = remainder.range(of: ":/") else {
            throw AcceptanceExternalLifecycleError.validationFailed("SFTP acceptance repository must include an absolute path.")
        }
        let hostPart = String(remainder[..<separator.lowerBound])
        let path = "/" + String(remainder[separator.upperBound...])
        let userAndHost = hostPart.split(separator: "@", maxSplits: 1).map(String.init)
        let username = userAndHost.count == 2 ? userAndHost[0] : nil
        let host = userAndHost.count == 2 ? userAndHost[1] : userAndHost[0]
        guard !host.isEmpty else {
            throw AcceptanceExternalLifecycleError.validationFailed("SFTP acceptance repository host is empty.")
        }
        return .sftp(
            host: host,
            path: path,
            username: username,
            port: nil,
            identityFilePath: identityFilePath
        )
    }

    private func s3Backend(repository: String, region: String?) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("s3:") else {
            throw AcceptanceExternalLifecycleError.validationFailed("S3 acceptance repository must start with s3:.")
        }
        let value = String(trimmed.dropFirst("s3:".count))
        guard let components = URLComponents(string: value), let scheme = components.scheme, let host = components.host else {
            throw AcceptanceExternalLifecycleError.validationFailed("S3 acceptance repository must include an endpoint URL, bucket, and path.")
        }
        let endpoint = "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")"
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let bucket = parts.first, !bucket.isEmpty else {
            throw AcceptanceExternalLifecycleError.validationFailed("S3 acceptance repository path must include a bucket.")
        }
        let path = parts.dropFirst().joined(separator: "/")
        return .s3(
            endpoint: endpoint,
            bucket: bucket,
            path: path.isEmpty ? nil : path,
            region: region
        )
    }

    private func restBackend(repository: String) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.hasPrefix("rest:") ? String(trimmed.dropFirst("rest:".count)) : trimmed
        guard
            let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host?.isEmpty == false
        else {
            throw AcceptanceExternalLifecycleError.validationFailed("REST acceptance repository must be rest:https://host/path or https://host/path.")
        }
        return .rest(url: url)
    }

    private func b2Backend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "b2:", name: "Backblaze B2")
        return .backblazeB2(bucket: parts.container, path: parts.path)
    }

    private func azureBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "azure:", name: "Azure Blob")
        return .azureBlob(container: parts.container, path: parts.path)
    }

    private func gcsBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "gs:", name: "Google Cloud Storage")
        return .googleCloudStorage(bucket: parts.container, path: parts.path)
    }

    private func swiftBackend(repository: String) throws -> RepositoryBackend {
        let parts = try objectStoreParts(repository: repository, prefix: "swift:", name: "OpenStack Swift")
        return .swiftObjectStorage(container: parts.container, path: parts.path)
    }

    private func rcloneBackend(repository: String) throws -> RepositoryBackend {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rclone:") else {
            throw AcceptanceExternalLifecycleError.validationFailed("rclone acceptance repository must start with rclone:.")
        }
        let remainder = String(trimmed.dropFirst("rclone:".count))
        guard let separator = remainder.firstIndex(of: ":") else {
            throw AcceptanceExternalLifecycleError.validationFailed("rclone acceptance repository must be rclone:remote:path.")
        }
        let remote = String(remainder[..<separator])
        let path = String(remainder[remainder.index(after: separator)...])
        guard !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AcceptanceExternalLifecycleError.validationFailed("rclone acceptance repository must include a remote and path.")
        }
        return .rclone(remote: remote, path: path)
    }

    private func objectStoreParts(repository: String, prefix: String, name: String) throws -> (container: String, path: String?) {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            throw AcceptanceExternalLifecycleError.validationFailed("\(name) acceptance repository must start with \(prefix).")
        }
        let remainder = String(trimmed.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":") else {
            throw AcceptanceExternalLifecycleError.validationFailed("\(name) acceptance repository must include a bucket/container and path separator.")
        }
        let container = String(remainder[..<separator])
        let rawPath = String(remainder[remainder.index(after: separator)...])
        guard !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AcceptanceExternalLifecycleError.validationFailed("\(name) acceptance repository bucket/container is empty.")
        }
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (container, path.isEmpty ? nil : path)
    }

    private func normalizedSFTPPath(_ path: String) -> String {
        if path.hasPrefix("//") {
            return String(path.dropFirst())
        }
        return path.isEmpty ? "/" : path
    }

    private func credentials(for kind: RepositoryBackendKind, environment: [String: String]) -> [String: String] {
        ResticBackendCredentialTemplates.keys(for: kind).reduce(into: [:]) { result, key in
            if let value = optionalCredential(key, environment: environment) {
                result[key] = value
            }
        }
    }

    private func customCredentials(environment: [String: String]) throws -> [String: String] {
        let keys = (environment["DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return try keys.reduce(into: [:]) { result, key in
            result[key] = try requiredCredential(key, environment: environment)
        }
    }

    private func optionalCredential(_ key: String, environment: [String: String]) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func requiredCredential(_ key: String, environment: [String: String]) throws -> String {
        guard let value = optionalCredential(key, environment: environment) else {
            throw AcceptanceExternalLifecycleError.validationFailed("\(key) is required.")
        }
        return value
    }

    private func requireAnyCredential(_ keys: [String], environment: [String: String]) throws {
        if keys.contains(where: { optionalCredential($0, environment: environment) != nil }) {
            return
        }
        throw AcceptanceExternalLifecycleError.validationFailed("One of \(keys.joined(separator: ", ")) is required.")
    }

    private func hasAll(_ keys: [String], in values: [String: String]) -> Bool {
        keys.allSatisfy { values[$0] != nil }
    }
}

private enum AcceptanceExternalLifecycleError: Error, LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
