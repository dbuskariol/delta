import DeltaCore
import Foundation

enum AcceptanceLocalLifecycleCommand {
    static func run(
        executableURL: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("delta-local-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appSupport = try AppDirectories.applicationSupportDirectory(fileManager: fileManager)
        let repositoryURL = root.appendingPathComponent("destination", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let documentsURL = sourceURL.appendingPathComponent("Documents", isDirectory: true)
        let photosURL = sourceURL.appendingPathComponent("Photos", isDirectory: true)
        let fullRestoreURL = root.appendingPathComponent("restore-full", isDirectory: true)
        let selectedRestoreURL = root.appendingPathComponent("restore-selected", isDirectory: true)
        let selectedFileRestoreURL = root.appendingPathComponent("restore-selected-file", isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosURL, withIntermediateDirectories: true)

        let reportURL = documentsURL.appendingPathComponent("report.txt")
        let imageURL = photosURL.appendingPathComponent("image.txt")
        let rootMarkerURL = sourceURL.appendingPathComponent("root.txt")
        try "Quarterly restore validation\n".write(to: reportURL, atomically: true, encoding: .utf8)
        try "image-bytes-\(timestamp)\n".write(to: imageURL, atomically: true, encoding: .utf8)
        try "root marker\n".write(to: rootMarkerURL, atomically: true, encoding: .utf8)

        let database = try DeltaDatabase.live()
        let repositoryID = UUID()
        let profileID = UUID()
        let keychainAccount = "local-lifecycle-\(repositoryID.uuidString)"
        let secretStore = KeychainSecretStore()
        try secretStore.save(
            secret: UUID().uuidString + UUID().uuidString,
            account: keychainAccount,
            authenticationPolicy: .failIfInteractionNeeded
        )
        defer { try? secretStore.delete(account: keychainAccount) }

        let repository = BackupRepository(
            id: repositoryID,
            name: "Installed Local Lifecycle",
            backend: .local(path: repositoryURL.path),
            keychainAccount: keychainAccount
        )
        let profile = BackupProfile(
            id: profileID,
            name: "Installed Local Lifecycle",
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
            secretBridgeArguments: ["--secret-bridge"]
        )
        let coordinator = BackupCoordinator(
            database: database,
            commandBuilder: commandBuilder
        )

        let firstRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(firstRun.status == .succeeded || firstRun.status == .warning, "First backup did not complete: \(firstRun.message ?? firstRun.status.displayName)")

        let noChangeRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(noChangeRun.status == .succeeded || noChangeRun.status == .warning, "No-change backup did not complete: \(noChangeRun.message ?? noChangeRun.status.displayName)")
        let noChangeSummary = try requireValue(noChangeRun.backupSummary, "No-change backup summary was missing.")
        try require(noChangeSummary.filesNew == 0, "No-change backup reported \(noChangeSummary.filesNew) new files.")
        try require(noChangeSummary.filesChanged == 0, "No-change backup reported \(noChangeSummary.filesChanged) changed files.")
        try require((noChangeSummary.dataBlobs ?? 0) == 0, "No-change backup reported new file data.")

        try "Quarterly restore validation updated\n".write(to: reportURL, atomically: true, encoding: .utf8)
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

        let documentEntries = try coordinator.listSnapshotEntries(
            repository: repository,
            snapshotID: latestSnapshot.id,
            directoryPath: documentsURL.path
        )
        try require(documentEntries.contains { $0.path == reportURL.path && $0.type == .file }, "Restore browser did not list report.txt inside Documents.")

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

        let selectedFileRestore = try coordinator.restore(
            request: RestoreRequest(
                repositoryID: repositoryID,
                snapshotID: latestSnapshot.id,
                scope: .selectedPaths([reportURL.path]),
                destination: .chosenFolder(selectedFileRestoreURL.path),
                dryRun: false
            ),
            repository: repository
        )
        try require(selectedFileRestore.status == .succeeded || selectedFileRestore.status == .warning, "Selected file restore did not complete: \(selectedFileRestore.message ?? selectedFileRestore.status.displayName)")
        try require(try contentsOfFirstFile(named: "report.txt", under: selectedFileRestoreURL)?.contains("updated") == true, "Selected file restore did not recover report.txt.")
        try require(try firstFile(named: "image.txt", under: selectedFileRestoreURL) == nil, "Selected file restore unexpectedly recovered image.txt.")

        let checkRun = try coordinator.check(repository: repository, readDataSubset: "1/100")
        try require(checkRun.status == .succeeded || checkRun.status == .warning, "Destination check did not complete: \(checkRun.message ?? checkRun.status.displayName)")

        let maintenanceRuns = try coordinator.runRetentionMaintenance(profile: profile, repository: repository)
        try require(maintenanceRuns.contains { $0.kind == .prune && ($0.status == .succeeded || $0.status == .warning) }, "Cleanup did not complete successfully.")
        try require(maintenanceRuns.contains { $0.kind == .check && ($0.status == .succeeded || $0.status == .warning) }, "Post-cleanup check did not run successfully.")

        let latestJobs = try database.fetchJobRuns(limit: 50)
        let backupCount = latestJobs.filter { $0.repositoryID == repositoryID && $0.kind == .backup }.count
        let restoreCount = latestJobs.filter { $0.repositoryID == repositoryID && $0.kind == .restore }.count
        let browseLogCount = rootEntries.count + documentEntries.count

        return """
        # Delta Installed Local Lifecycle Acceptance

        - Generated: \(timestamp)
        - App: \(bundle.bundleURL.path)
        - Executable: \(executableURL.path)
        - Application Support: \(appSupport.path)
        - Restic: \(resticURL.path)
        - Temporary destination: \(repositoryURL.path)

        This verifies the installed Delta app's own coordinator against a temporary encrypted local destination. It uses Delta's SQLite store, Keychain password command, bundled restic, automatic destination preparation, restore-point cache, browser listing, restore command construction, destination checks, and retention cleanup.

        ## Result

        Installed local lifecycle acceptance passed.

        - First backup status: \(firstRun.status.displayName)
        - No-change backup: \(noChangeSummary.conciseText)
        - Incremental backup: \(incrementalSummary.detailedText)
        - Cached restore points: \(snapshots.count)
        - Latest restore point: \(latestSnapshot.id)
        - Restore browser entries verified: \(browseLogCount)
        - Full restore status: \(fullRestore.status.displayName)
        - Selected folder restore status: \(selectedFolderRestore.status.displayName)
        - Selected file restore status: \(selectedFileRestore.status.displayName)
        - Destination check status: \(checkRun.status.displayName)
        - Cleanup runs: \(maintenanceRuns.map { $0.kind.displayName + " " + $0.status.displayName }.joined(separator: ", "))
        - Stored backup jobs: \(backupCount)
        - Stored restore jobs: \(restoreCount)
        - Keychain item deleted on exit: Yes
        """
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw AcceptanceLocalLifecycleError.validationFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw AcceptanceLocalLifecycleError.validationFailed(message)
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

private enum AcceptanceLocalLifecycleError: Error, LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
