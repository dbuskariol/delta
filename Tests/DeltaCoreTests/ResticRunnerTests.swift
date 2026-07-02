import XCTest
@testable import DeltaCore

final class ResticRunnerTests: XCTestCase {
    func testRunnerStreamsStandardOutputAndErrorBeforeReturningFinalResult() throws {
        let recorder = OutputRecorder()
        let runner = ResticRunner { event in
            recorder.append(event)
        }
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2"]
        )

        let result = try runner.run(command)
        let events = recorder.events

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(events.contains { $0.stream == .standardOutput && $0.message == "stdout-line" })
        XCTAssertTrue(events.contains { $0.stream == .standardError && $0.message == "stderr-line" })
        XCTAssertEqual(result.standardOutput, "stdout-line\n")
        XCTAssertEqual(result.standardError, "stderr-line\n")
    }

    func testRunnerCanPauseRunningProcess() throws {
        let controller = ResticRunController()
        let runner = ResticRunner(runController: controller)
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'echo interrupted >&2; exit 130' INT; while true; do sleep 1; done"]
        )
        let completion = DispatchSemaphore(value: 0)
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.result = try runner.run(command)
            } catch {
                box.error = error
            }
            completion.signal()
        }

        Thread.sleep(forTimeInterval: 0.25)
        controller.requestStop(.pause)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        XCTAssertNil(box.error)
        XCTAssertEqual(box.result?.status, .cancelled)
        XCTAssertEqual(box.result?.failureKind, .interrupted)
        XCTAssertTrue(box.result?.userFacingMessage.localizedCaseInsensitiveContains("paused") == true)
    }

    func testControlStorePersistsAndClearsStopRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ResticRunControlStore(directoryProvider: { directory })
        let jobID = UUID()

        try store.requestStop(jobID: jobID, reason: .pause)

        XCTAssertEqual(try store.stopRequest(for: jobID)?.reason, .pause)
        XCTAssertEqual(store.stopReason(for: jobID), .pause)

        store.clearStopRequest(jobID: jobID)

        XCTAssertNil(try store.stopRequest(for: jobID))
    }

    func testRunnerHonorsExternalStopProvider() throws {
        let runner = ResticRunner()
        let stopBox = StopRequestBox()
        let command = ResticCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'echo interrupted >&2; exit 130' INT; while true; do sleep 1; done"]
        )
        let completion = DispatchSemaphore(value: 0)
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.result = try runner.run(command, outputHandler: nil) {
                    stopBox.reason
                }
            } catch {
                box.error = error
            }
            completion.signal()
        }

        Thread.sleep(forTimeInterval: 0.25)
        stopBox.reason = .cancel

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        XCTAssertNil(box.error)
        XCTAssertEqual(box.result?.status, .cancelled)
        XCTAssertEqual(box.result?.failureKind, .interrupted)
        XCTAssertTrue(box.result?.userFacingMessage.localizedCaseInsensitiveContains("cancelled") == true)
        XCTAssertFalse(box.result?.userFacingMessage.localizedCaseInsensitiveContains("restic") == true)
    }

    func testLogFormatterTurnsResticStatusJSONIntoReadableProgress() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"status","percent_done":0.42,"files_done":21,"total_files":50,"bytes_done":1048576}
        """)

        XCTAssertEqual(message, "Processed 21 files · 1 MB")
        XCTAssertTrue(ResticLogFormatter.isStatusMessage("""
        {"message_type":"status","percent_done":0.42,"files_done":21,"total_files":50,"bytes_done":1048576}
        """))
    }

    func testLogFormatterExposesProgressSnapshotForStatusJSON() {
        let snapshot = ResticLogFormatter.progressSnapshot(for: """
        {"message_type":"status","percent_done":0.42,"files_done":21,"total_files":50,"bytes_done":1048576,"current_files":["/Users/me/Documents/Projects/Delta/file.txt"]}
        """)

        XCTAssertEqual(snapshot?.percentDone, 0.42)
        XCTAssertEqual(snapshot?.filesDone, 21)
        XCTAssertEqual(snapshot?.totalFiles, 50)
        XCTAssertEqual(snapshot?.bytesDone, 1_048_576)
        XCTAssertEqual(snapshot?.currentPath, "/Users/me/Documents/Projects/Delta/file.txt")
        XCTAssertEqual(snapshot?.displayMessage, "Processed 21 files · 1 MB · Current .../Projects/Delta/file.txt")
    }

    func testLogFormatterShowsCurrentFileWhenResticReportsIt() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"status","percent_done":0.42,"files_done":21,"total_files":50,"bytes_done":1048576,"current_files":["/Users/me/Documents/Projects/Delta/file.txt"]}
        """)

        XCTAssertEqual(message, "Processed 21 files · 1 MB · Current .../Projects/Delta/file.txt")
    }

    func testLogFormatterShowsBackupSummaryChangeCounts() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"summary","files_new":2,"files_changed":3,"files_unmodified":95,"data_added":1048576,"total_files_processed":100,"total_bytes_processed":2097152,"snapshot_id":"snapshot-id"}
        """)
        let summary = ResticLogFormatter.backupSummary(from: """
        {"message_type":"status","files_done":100}
        {"message_type":"summary","files_new":2,"files_changed":3,"files_unmodified":95,"data_added":1048576,"total_files_processed":100,"total_bytes_processed":2097152,"snapshot_id":"snapshot-id"}
        """)
        let finalSummaryMessage = ResticLogFormatter.finalSummaryMessage(from: """
        {"message_type":"status","files_done":100}
        {"message_type":"summary","files_new":2,"files_changed":3,"files_unmodified":95,"data_added":1048576,"total_files_processed":100,"total_bytes_processed":2097152,"snapshot_id":"snapshot-id"}
        """)
        let result = ResticRunResult(
            exitCode: 0,
            standardOutput: """
            {"message_type":"status","files_done":100}
            {"message_type":"summary","files_new":2,"files_changed":3,"files_unmodified":95,"data_added":1048576,"total_files_processed":100,"total_bytes_processed":2097152,"snapshot_id":"snapshot-id"}
            """,
            standardError: ""
        )

        XCTAssertEqual(message, "Backup summary · 2 new · 3 changed · 95 unchanged · 1 MB added")
        XCTAssertEqual(summary?.conciseText, "2 new · 3 changed · 1 MB added")
        XCTAssertEqual(summary?.detailedText, "2 new · 3 changed · 95 unchanged · 1 MB added")
        XCTAssertEqual(summary?.snapshotID, "snapshot-id")
        XCTAssertEqual(finalSummaryMessage, "Backup summary · 2 new · 3 changed · 95 unchanged · 1 MB added")
        XCTAssertEqual(result.userFacingMessage, "Backup summary · 2 new · 3 changed · 95 unchanged · 1 MB added")
    }

    func testLogFormatterCallsOutUnchangedBackups() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"summary","files_new":0,"files_changed":0,"files_unmodified":100,"data_added":0,"total_files_processed":100,"total_bytes_processed":2097152}
        """)

        XCTAssertEqual(message, "No changes detected · 0 new · 0 changed · 2.1 MB checked")
    }

    func testLogFormatterTreatsMetadataOnlyBackupAsUnchanged() throws {
        let output = """
        {"message_type":"summary","files_new":0,"files_changed":0,"files_unmodified":100,"data_blobs":0,"tree_blobs":1,"data_added":512,"total_files_processed":100,"total_bytes_processed":2097152}
        """

        let summary = try XCTUnwrap(ResticLogFormatter.backupSummary(from: output))

        XCTAssertFalse(summary.hasChanges)
        XCTAssertEqual(summary.dataBlobs, 0)
        XCTAssertEqual(summary.conciseText, "0 new · 0 changed · 2.1 MB checked")
        XCTAssertEqual(summary.logText, "No changes detected · 0 new · 0 changed · 2.1 MB checked")
    }

    func testLogFormatterDoesNotTreatGenericSummaryAsBackupSummary() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"summary","total_files":12,"total_bytes":4096}
        """)

        XCTAssertEqual(message, "Operation summary · 12 files · 4 KB")
    }

    func testLogFormatterTurnsResticErrorJSONIntoReadableItemMessage() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"error","message":"permission denied","item":"/Users/me/Library/Mail"}
        """)

        XCTAssertEqual(message, "permission denied: /Users/me/Library/Mail")
    }

    func testLogFormatterRedactsCredentialsFromPlainAndJSONMessages() {
        let plainMessage = ResticLogFormatter.displayMessage(
            for: "Fatal: unable to open rest:https://user:secret@example.com/repo AWS_SECRET_ACCESS_KEY=abc123"
        )
        let jsonMessage = ResticLogFormatter.displayMessage(for: """
        {"message_type":"error","message":"failed for rest:https://user:secret@example.com/repo","item":"OS_PASSWORD=hunter2"}
        """)

        XCTAssertTrue(plainMessage.contains("rest:https://<redacted>@example.com/repo"))
        XCTAssertTrue(plainMessage.contains("AWS_SECRET_ACCESS_KEY=<redacted>"))
        XCTAssertFalse(plainMessage.contains("user:secret"))
        XCTAssertFalse(plainMessage.contains("abc123"))
        XCTAssertTrue(jsonMessage.contains("rest:https://<redacted>@example.com/repo"))
        XCTAssertTrue(jsonMessage.contains("OS_PASSWORD=<redacted>"))
        XCTAssertFalse(jsonMessage.contains("hunter2"))
    }

    func testRunResultRedactsCredentialsFromFallbackUserFacingMessage() {
        let result = ResticRunResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "Fatal: unable to open rest:https://user:secret@example.com/repo B2_ACCOUNT_KEY=abc123"
        )

        XCTAssertTrue(result.userFacingMessage.contains("rest:https://<redacted>@example.com/repo"))
        XCTAssertTrue(result.userFacingMessage.contains("B2_ACCOUNT_KEY=<redacted>"))
        XCTAssertFalse(result.userFacingMessage.contains("user:secret"))
        XCTAssertFalse(result.userFacingMessage.contains("abc123"))
    }

    func testExitCodeThreeMapsToUnreadableSourceWarningWithoutOutputText() {
        let result = ResticRunResult(exitCode: 3, standardOutput: "", standardError: "")

        XCTAssertEqual(result.status, .warning)
        XCTAssertEqual(result.failureKind, .unreadableSourceFiles)
        XCTAssertEqual(
            result.userFacingMessage,
            "Backup completed, but some files could not be read. Check Full Disk Access and source permissions."
        )
    }

    func testGenericPermissionDeniedDoesNotMasqueradeAsUnreadableSourceWarning() {
        let result = ResticRunResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "Fatal: mkdir /restore/private: permission denied"
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .permissionDenied)
        XCTAssertEqual(
            result.userFacingMessage,
            "Delta does not have permission to read or write one of the selected paths. Check the source, restore target, destination, and Full Disk Access permissions."
        )
    }

    func testPasswordCommandFailureMapsToRepairableDestinationSecretMessage() {
        let result = ResticRunResult(
            exitCode: 1,
            standardOutput: "",
            standardError: """
            DeltaSecretBridge error: The saved destination secret is missing.
            Fatal: Resolving password failed: exit status 1
            """
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureKind, .destinationSecretUnavailable)
        XCTAssertEqual(
            result.userFacingMessage,
            "Delta could not read the saved destination password. Use Repair Password Access in Settings or re-save the destination."
        )
    }

    func testClassifiedFailureMessagesUseProductLanguage() {
        let classifiedKinds = ResticFailureKind.allCases.filter { $0 != .unknown }
        let forbiddenTerms = [
            "repository",
            "restic",
            "LaunchAgent",
            "SMAppService"
        ]

        for kind in classifiedKinds {
            let message = ResticFailureClassifier.userFacingMessage(
                status: .failed,
                failureKind: kind,
                standardOutput: "",
                standardError: ""
            )

            for term in forbiddenTerms {
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(term),
                    "\(kind.rawValue) message exposes implementation term '\(term)': \(message)"
                )
            }
        }
    }
}

private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ResticOutputEvent] = []

    var events: [ResticOutputEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func append(_ event: ResticOutputEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: ResticRunResult?
    private var storedError: Error?

    var result: ResticRunResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
        set {
            lock.lock()
            storedResult = newValue
            lock.unlock()
        }
    }

    var error: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
        set {
            lock.lock()
            storedError = newValue
            lock.unlock()
        }
    }
}

private final class StopRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReason: ResticRunStopReason?

    var reason: ResticRunStopReason? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedReason
        }
        set {
            lock.lock()
            storedReason = newValue
            lock.unlock()
        }
    }
}
