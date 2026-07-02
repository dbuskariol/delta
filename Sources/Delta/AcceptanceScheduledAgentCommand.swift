import DeltaCore
import Foundation

enum AcceptanceScheduledAgentCommand {
    private static let manifestName = "scheduled-agent-manifest.json"

    static func seed(workDirectory: URL, keychainAccount: String, bundle: Bundle = .main) throws -> String {
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let root = workDirectory.standardizedFileURL
        let supportURL = try AppDirectories.applicationSupportDirectory()
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        let documentsURL = sourceURL.appendingPathComponent("Documents", isDirectory: true)
        let reportURL = documentsURL.appendingPathComponent("scheduled-report.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Scheduled helper acceptance \(timestamp)\n".write(to: reportURL, atomically: true, encoding: .utf8)

        let repositoryID = UUID()
        let profileID = UUID()
        let secretStore = KeychainSecretStore()
        try secretStore.save(
            secret: UUID().uuidString + UUID().uuidString,
            account: keychainAccount,
            authenticationPolicy: .failIfInteractionNeeded
        )

        let repository = BackupRepository(
            id: repositoryID,
            name: "Scheduled Helper Acceptance",
            backend: .local(path: destinationURL.path),
            keychainAccount: keychainAccount
        )
        let profile = BackupProfile(
            id: profileID,
            name: "Scheduled Helper Acceptance",
            sourceMode: .customFolders,
            sources: [BackupSource(path: sourceURL.path)],
            repositoryID: repositoryID,
            schedule: BackupSchedule(
                kind: .customInterval(seconds: 60),
                isEnabled: true,
                catchUpMissedRuns: true,
                runOnBattery: true,
                runInLowPowerMode: true
            ),
            retention: RetentionPolicy(
                keepHourly: 1,
                keepDaily: 0,
                keepWeekly: 0,
                keepMonthly: 0,
                keepYearly: 0,
                pruneAfterForget: false,
                checkAfterPrune: false,
                maintenanceSchedule: RetentionMaintenanceSchedule(isEnabled: false)
            )
        )

        let database = try DeltaDatabase.live()
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        let manifest = Manifest(
            generatedAt: timestamp,
            appPath: bundle.bundleURL.path,
            supportPath: supportURL.path,
            repositoryID: repositoryID,
            profileID: profileID,
            keychainAccount: keychainAccount,
            sourcePath: sourceURL.path,
            destinationPath: destinationURL.path,
            expectedFilePath: reportURL.path
        )
        try writeManifest(manifest, to: root)

        return """
        Seeded scheduled helper acceptance state.
        - Application Support: \(supportURL.path)
        - Source: \(sourceURL.path)
        - Destination: \(destinationURL.path)
        - Profile: \(profileID.uuidString)
        - Destination ID: \(repositoryID.uuidString)
        - Keychain account: \(keychainAccount)
        """
    }

    static func verify(workDirectory: URL, keychainAccount: String, bundle: Bundle = .main) throws -> String {
        let manifest = try readManifest(from: workDirectory.standardizedFileURL)
        guard manifest.keychainAccount == keychainAccount else {
            throw AcceptanceScheduledAgentError.validationFailed("The supplied keychain account does not match the seeded manifest.")
        }

        defer { try? KeychainSecretStore().delete(account: keychainAccount) }

        let database = try DeltaDatabase.live()
        let jobs = try database.fetchJobRuns(limit: 100)
            .filter { $0.repositoryID == manifest.repositoryID }
        let backupJobs = jobs.filter { $0.profileID == manifest.profileID && $0.kind == .backup }
        guard let backup = backupJobs.max(by: { $0.startedAt < $1.startedAt }) else {
            throw AcceptanceScheduledAgentError.validationFailed("DeltaAgent did not record a scheduled backup job.")
        }
        guard backup.status == .succeeded || backup.status == .warning else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup finished with \(backup.status.displayName): \(backup.message ?? "No message")")
        }
        guard let summary = backup.backupSummary else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup did not persist a structured backup summary.")
        }
        guard summary.totalFilesProcessed > 0 || summary.filesNew > 0 || summary.filesChanged > 0 else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup summary did not report processed files.")
        }

        let initJobs = jobs.filter { $0.kind == .initializeRepository && ($0.status == .succeeded || $0.status == .warning) }
        guard !initJobs.isEmpty else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup did not automatically prepare the empty local destination.")
        }

        let snapshots = try database.fetchSnapshots(repositoryID: manifest.repositoryID)
        guard !snapshots.isEmpty else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup did not refresh cached restore points.")
        }
        guard snapshots.contains(where: { $0.paths.contains(manifest.sourcePath) }) else {
            throw AcceptanceScheduledAgentError.validationFailed("Cached restore points did not include the seeded source path.")
        }
        guard FileManager.default.fileExists(atPath: manifest.destinationPath + "/config") else {
            throw AcceptanceScheduledAgentError.validationFailed("Prepared destination is missing the restic config file.")
        }

        let logs = try database.fetchJobLogs(jobID: backup.id)
        guard logs.contains(where: { $0.message.contains("Source: \(manifest.sourcePath)") }) else {
            throw AcceptanceScheduledAgentError.validationFailed("Scheduled backup logs did not include source context.")
        }

        return """
        # Delta Installed Scheduled Helper Acceptance

        - Generated: \(ISO8601DateFormatter().string(from: Date()))
        - App: \(bundle.bundleURL.path)
        - Application Support: \(manifest.supportPath)
        - Source: \(manifest.sourcePath)
        - Destination: \(manifest.destinationPath)

        This verifies the installed Scheduled Backups helper against isolated Delta state. The helper runs the installed Delta executable, reads the saved destination password non-interactively, prepares a missing encrypted local destination, runs one due scheduled backup, persists job logs and a structured backup summary, and refreshes cached restore points.

        ## Result

        Installed scheduled helper acceptance passed.

        - Helper-started backup status: \(backup.status.displayName)
        - Backup summary: \(summary.detailedText)
        - Automatic destination preparation jobs: \(initJobs.count)
        - Cached restore points: \(snapshots.count)
        - Source context logged: Yes
        - Keychain item deleted on exit: Yes
        """
    }

    private static func manifestURL(for root: URL) -> URL {
        root.appendingPathComponent(manifestName)
    }

    private static func writeManifest(_ manifest: Manifest, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: root), options: .atomic)
    }

    private static func readManifest(from root: URL) throws -> Manifest {
        let data = try Data(contentsOf: manifestURL(for: root))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private struct Manifest: Codable {
        var generatedAt: String
        var appPath: String
        var supportPath: String
        var repositoryID: UUID
        var profileID: UUID
        var keychainAccount: String
        var sourcePath: String
        var destinationPath: String
        var expectedFilePath: String
    }
}

private enum AcceptanceScheduledAgentError: Error, LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
