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

    func testLogFormatterTurnsResticErrorJSONIntoReadableItemMessage() {
        let message = ResticLogFormatter.displayMessage(for: """
        {"message_type":"error","message":"permission denied","item":"/Users/me/Library/Mail"}
        """)

        XCTAssertEqual(message, "permission denied: /Users/me/Library/Mail")
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
