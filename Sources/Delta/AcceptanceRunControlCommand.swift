import DeltaCore
import Foundation

enum AcceptanceRunControlCommand {
    static func run(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("delta-run-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appSupport = try AppDirectories.applicationSupportDirectory(fileManager: fileManager)
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        let controlsURL = root.appendingPathComponent("controls", isDirectory: true)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: controlsURL, withIntermediateDirectories: true)
        try "prepared restic config marker\n".write(
            to: destinationURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try "run-control acceptance \(timestamp)\n".write(
            to: sourceURL.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let database = try DeltaDatabase.live()
        let repository = BackupRepository(
            name: "Run Control Acceptance Destination",
            backend: .local(path: destinationURL.path)
        )
        let profile = BackupProfile(
            name: "Run Control Acceptance Profile",
            sourceMode: .customFolders,
            sources: [BackupSource(path: sourceURL.path)],
            repositoryID: repository.id,
            schedule: BackupSchedule(kind: .hourly(minute: 0), isEnabled: false)
        )
        try database.saveRepository(repository)
        try database.saveProfile(profile)

        let runControlStore = ResticRunControlStore(directoryProvider: { controlsURL })
        let runner = AcceptanceRunControlRunner(sourcePath: sourceURL.path)
        let commandBuilder = ResticCommandBuilder(
            resticExecutableURL: URL(fileURLWithPath: "/usr/bin/restic"),
            secretBridgeURL: URL(fileURLWithPath: bundle.executableURL?.path ?? "/usr/bin/false"),
            baseEnvironment: [:]
        )
        let coordinator = BackupCoordinator(
            database: database,
            commandBuilder: commandBuilder,
            runner: runner,
            runControlStore: runControlStore,
            outputHandler: nil
        )

        let pausedRun = try runBackupAndRequestStop(
            reason: .pause,
            profile: profile,
            repository: repository,
            coordinator: coordinator,
            database: database,
            runControlStore: runControlStore
        )
        try require(pausedRun.status == .cancelled, "Pause run finished with \(pausedRun.status.displayName).")
        try require(pausedRun.stopReason == .pause, "Pause run did not persist a pause stop reason.")
        try require(pausedRun.isPausedBackup, "Paused backup was not marked resumable.")
        try require(try runControlStore.stopRequest(for: pausedRun.id) == nil, "Pause stop request was not cleared after completion.")
        let pausedLogs = try database.fetchJobLogs(jobID: pausedRun.id, limit: 200)
        try require(pausedLogs.contains { $0.message.localizedCaseInsensitiveContains("paused") }, "Pause run did not persist a paused log line.")

        let resumedRun = try coordinator.runBackup(profile: profile, repository: repository)
        try require(resumedRun.status == .succeeded || resumedRun.status == .warning, "Resume run did not complete: \(resumedRun.message ?? resumedRun.status.displayName).")
        try require(!resumedRun.isPausedBackup, "Successful resume was incorrectly marked resumable.")
        try require(resumedRun.backupSummary?.snapshotID == AcceptanceRunControlRunner.snapshotID, "Resume run did not persist the expected structured backup summary.")
        let snapshots = try database.fetchSnapshots(repositoryID: repository.id)
        try require(snapshots.map(\.id).contains(AcceptanceRunControlRunner.snapshotID), "Resume run did not refresh cached restore points.")
        try require(latestBackup(for: profile.id, in: database)?.id == resumedRun.id, "Successful resume was not the latest backup run.")

        let cancelledRun = try runBackupAndRequestStop(
            reason: .cancel,
            profile: profile,
            repository: repository,
            coordinator: coordinator,
            database: database,
            runControlStore: runControlStore
        )
        try require(cancelledRun.status == .cancelled, "Cancel run finished with \(cancelledRun.status.displayName).")
        try require(cancelledRun.stopReason == .cancel, "Cancel run did not persist a cancel stop reason.")
        try require(!cancelledRun.isPausedBackup, "Cancelled backup was incorrectly marked resumable.")
        try require(try runControlStore.stopRequest(for: cancelledRun.id) == nil, "Cancel stop request was not cleared after completion.")
        let cancelledLogs = try database.fetchJobLogs(jobID: cancelledRun.id, limit: 200)
        try require(cancelledLogs.contains { $0.message.localizedCaseInsensitiveContains("cancelled") }, "Cancel run did not persist a cancelled log line.")
        try require(latestBackup(for: profile.id, in: database)?.id == cancelledRun.id, "Cancelled run was not the latest backup run.")
        try require(!cancelledRun.isPausedBackup, "Latest cancelled run should not show Resume.")

        let commands = runner.commandNames
        try require(commands == ["backup", "backup", "snapshots", "backup"], "Unexpected run-control command sequence: \(commands.joined(separator: ", ")).")

        return """
        # Delta Installed Run Control Acceptance

        - Generated: \(timestamp)
        - App: \(bundle.bundleURL.path)
        - Application Support: \(appSupport.path)
        - Source: \(sourceURL.path)
        - Destination: \(destinationURL.path)

        This verifies Delta's installed app process can persist and honor durable backup stop requests. The probe runs through the real coordinator, SQLite job store, job log persistence, source preflight, destination lock, and run-control store with a deterministic controlled runner so pause and cancel are not timing-sensitive.

        ## Result

        Installed run-control acceptance passed.

        - Pause status: \(pausedRun.status.displayName)
        - Pause stop reason: \(pausedRun.stopReason?.rawValue ?? "missing")
        - Paused backup remains resumable: \(pausedRun.isPausedBackup ? "Yes" : "No")
        - Resume status: \(resumedRun.status.displayName)
        - Resume refreshed restore points: \(snapshots.count)
        - Cancel status: \(cancelledRun.status.displayName)
        - Cancel stop reason: \(cancelledRun.stopReason?.rawValue ?? "missing")
        - Cancelled backup is resumable: \(cancelledRun.isPausedBackup ? "Yes" : "No")
        - Stop requests cleared: Yes
        - Command sequence: \(commands.joined(separator: ", "))
        """
    }

    private static func runBackupAndRequestStop(
        reason: ResticRunStopReason,
        profile: BackupProfile,
        repository: BackupRepository,
        coordinator: BackupCoordinator,
        database: DeltaDatabase,
        runControlStore: ResticRunControlStore
    ) throws -> JobRun {
        let completedJob = DispatchSemaphore(value: 0)
        let box = LockedBox<RunResult?>(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let run = try coordinator.runBackup(profile: profile, repository: repository)
                box.value = .success(run)
            } catch {
                box.value = .failure(error)
            }
            completedJob.signal()
        }

        let jobID = try waitForRunningBackup(
            profileID: profile.id,
            database: database
        )
        try runControlStore.requestStop(jobID: jobID, reason: reason)

        guard completedJob.wait(timeout: .now() + 5) == .success else {
            throw AcceptanceRunControlError.validationFailed("Timed out waiting for \(reason.rawValue) run to finish.")
        }
        switch try requireValue(box.value, "Run-control backup did not produce a result.") {
        case let .success(run):
            return run
        case let .failure(error):
            throw error
        }
    }

    private static func waitForRunningBackup(
        profileID: UUID,
        database: DeltaDatabase
    ) throws -> UUID {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let job = try database.fetchJobRuns(limit: 200)
                .first(where: { $0.profileID == profileID && $0.kind == .backup && $0.status == .running }) {
                return job.id
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AcceptanceRunControlError.validationFailed("Timed out waiting for a running backup job.")
    }

    private static func latestBackup(for profileID: UUID, in database: DeltaDatabase) throws -> JobRun? {
        try database.fetchJobRuns(limit: 200)
            .filter { $0.profileID == profileID && $0.kind == .backup }
            .max { $0.startedAt < $1.startedAt }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw AcceptanceRunControlError.validationFailed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw AcceptanceRunControlError.validationFailed(message)
        }
        return value
    }
}

private final class AcceptanceRunControlRunner: ResticControlledStreamingRunning, @unchecked Sendable {
    static let snapshotID = "run-control-resume-snapshot"

    private enum BackupBehavior {
        case waitForStop
        case succeed
    }

    private let lock = NSLock()
    private var backupBehaviors: [BackupBehavior] = [.waitForStop, .succeed, .waitForStop]
    private var storedCommandNames: [String] = []
    private let sourcePath: String

    init(sourcePath: String) {
        self.sourcePath = sourcePath
    }

    var commandNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommandNames
    }

    func run(_ command: ResticCommand) throws -> ResticRunResult {
        try run(command, outputHandler: nil, stopReasonProvider: nil)
    }

    func run(_ command: ResticCommand, outputHandler: (@Sendable (ResticOutputEvent) -> Void)?) throws -> ResticRunResult {
        try run(command, outputHandler: outputHandler, stopReasonProvider: nil)
    }

    func run(
        _ command: ResticCommand,
        outputHandler: (@Sendable (ResticOutputEvent) -> Void)?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) throws -> ResticRunResult {
        let subcommand = command.resticSubcommand ?? "unknown"
        let behavior: BackupBehavior?
        lock.lock()
        storedCommandNames.append(subcommand)
        behavior = subcommand == "backup" ? backupBehaviors.removeFirst() : nil
        lock.unlock()

        switch subcommand {
        case "backup":
            guard let behavior else {
                return ResticRunResult(exitCode: 1, standardOutput: "", standardError: "missing backup behavior")
            }
            return runBackup(behavior: behavior, outputHandler: outputHandler, stopReasonProvider: stopReasonProvider)
        case "snapshots":
            return ResticRunResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")
        default:
            return ResticRunResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }
    }

    private func runBackup(
        behavior: BackupBehavior,
        outputHandler: (@Sendable (ResticOutputEvent) -> Void)?,
        stopReasonProvider: (@Sendable () -> ResticRunStopReason?)?
    ) -> ResticRunResult {
        outputHandler?(
            ResticOutputEvent(
                stream: .standardOutput,
                message: #"{"message_type":"status","percent_done":0.12,"files_done":1,"total_files":10,"bytes_done":1024}"#
            )
        )

        switch behavior {
        case .succeed:
            let summary = """
            {"message_type":"summary","files_new":0,"files_changed":1,"files_unmodified":9,"data_added":2048,"total_files_processed":10,"total_bytes_processed":4096,"snapshot_id":"\(Self.snapshotID)"}
            """
            outputHandler?(ResticOutputEvent(stream: .standardOutput, message: summary))
            return ResticRunResult(exitCode: 0, standardOutput: summary, standardError: "")
        case .waitForStop:
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let reason = stopReasonProvider?() {
                    return ResticRunResult(
                        exitCode: 130,
                        standardOutput: "",
                        standardError: "\(reason.rawValue) requested",
                        stopReason: reason
                    )
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return ResticRunResult(exitCode: 1, standardOutput: "", standardError: "timed out waiting for stop request")
        }
    }

    private var snapshotJSON: String {
        """
        [
          {
            "id": "\(Self.snapshotID)",
            "time": "2026-07-02T10:00:00Z",
            "tree": "tree",
            "paths": ["\(sourcePath)"],
            "tags": ["delta"]
          }
        ]
        """
    }
}

private extension ResticCommand {
    var resticSubcommand: String? {
        arguments.first { ["backup", "forget", "check", "restore", "snapshots", "init", "ls"].contains($0) }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private enum RunResult {
    case success(JobRun)
    case failure(Error)
}

private enum AcceptanceRunControlError: Error, LocalizedError {
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .validationFailed(message):
            return message
        }
    }
}
