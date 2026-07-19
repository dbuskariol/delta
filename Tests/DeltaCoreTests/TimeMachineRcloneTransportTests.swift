import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineRcloneTransportTests: XCTestCase {
    func testConfigurationBuilderMapsS3AndDoesNotInheritUnrelatedProcessState() throws {
        let credentials = [
            "access": "test-access-key",
            "secret": "test-secret-key",
            "session": "test-session-token"
        ]
        let resolver = RepositoryCredentialResolver(
            loadSecret: { account in
                try XCTUnwrap(credentials[account])
            },
            saveSecret: { _, _ in },
            deleteSecret: { _ in }
        )
        let repository = BackupRepository(
            name: "Remote Time Machine",
            backend: .s3(
                endpoint: "https://storage.example.test",
                bucket: "backups",
                path: "/mac/history/",
                region: "test-1"
            ),
            format: .timeMachine,
            credentialReferences: [
                RepositoryCredentialReference(
                    environmentKey: "AWS_ACCESS_KEY_ID",
                    keychainAccount: "access"
                ),
                RepositoryCredentialReference(
                    environmentKey: "AWS_SECRET_ACCESS_KEY",
                    keychainAccount: "secret"
                ),
                RepositoryCredentialReference(
                    environmentKey: "AWS_SESSION_TOKEN",
                    keychainAccount: "session"
                )
            ]
        )

        let configuration = try TimeMachineRcloneConfigurationBuilder(
            rcloneExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            credentialResolver: resolver,
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/tester",
                "TMPDIR": "/private/tmp",
                "LANG": "en_AU.UTF-8",
                "UNRELATED_SECRET": "must-not-cross-the-process-boundary"
            ]
        ).configuration(for: repository)

        XCTAssertEqual(configuration.remoteRoot, "delta:backups/mac/history")
        XCTAssertEqual(configuration.environment["RCLONE_CONFIG_DELTA_TYPE"], "s3")
        XCTAssertEqual(configuration.environment["RCLONE_CONFIG_DELTA_PROVIDER"], "Other")
        XCTAssertEqual(
            configuration.environment["RCLONE_CONFIG_DELTA_ENDPOINT"],
            "https://storage.example.test"
        )
        XCTAssertEqual(configuration.environment["RCLONE_CONFIG_DELTA_REGION"], "test-1")
        XCTAssertEqual(configuration.environment["AWS_ACCESS_KEY_ID"], "test-access-key")
        XCTAssertEqual(configuration.environment["AWS_SECRET_ACCESS_KEY"], "test-secret-key")
        XCTAssertEqual(configuration.environment["AWS_SESSION_TOKEN"], "test-session-token")
        XCTAssertEqual(configuration.environment["HOME"], "/Users/tester")
        XCTAssertEqual(configuration.environment["TMPDIR"], "/private/tmp")
        XCTAssertEqual(configuration.environment["LANG"], "en_AU.UTF-8")
        XCTAssertNil(configuration.environment["UNRELATED_SECRET"])
        XCTAssertTrue(
            configuration.stagingDirectoryURL?.path.hasSuffix("/transport-staging") == true
        )
    }

    func testConfiguredRcloneRemoteUsesSavedConfigThroughExplicitConfigArgument() throws {
        let repository = BackupRepository(
            name: "Configured Remote",
            backend: .rclone(remote: "vault", path: "/mac/backups/"),
            format: .timeMachine,
            credentialReferences: [
                RepositoryCredentialReference(
                    environmentKey: "RCLONE_CONFIG",
                    keychainAccount: "config"
                )
            ]
        )
        let resolver = RepositoryCredentialResolver(
            loadSecret: { account in
                XCTAssertEqual(account, "config")
                return "/Users/tester/.config/rclone/rclone.conf"
            },
            saveSecret: { _, _ in },
            deleteSecret: { _ in }
        )
        let configuration = try TimeMachineRcloneConfigurationBuilder(
            rcloneExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            credentialResolver: resolver,
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        ).configuration(for: repository)
        let runner = RecordingTimeMachineRunner(output: Data("payload".utf8))
        let transport = TimeMachineRcloneObjectTransport(
            configuration: configuration,
            runner: runner
        )

        XCTAssertEqual(try transport.readObject(at: "objects/example"), Data("payload".utf8))
        let arguments = try XCTUnwrap(runner.snapshot().first)
        XCTAssertEqual(configuration.remoteRoot, "vault:mac/backups")
        XCTAssertTrue(arguments.contains("--config"))
        XCTAssertTrue(arguments.contains("/Users/tester/.config/rclone/rclone.conf"))
        XCTAssertTrue(arguments.contains("vault:mac/backups/objects/example"))
    }

    func testConfigurationBuilderRejectsDeltaOnlyBackendBeforeRemoteMutation() {
        let repository = BackupRepository(
            name: "REST",
            backend: .rest(url: "https://example.test/repository"),
            format: .timeMachine
        )
        let builder = TimeMachineRcloneConfigurationBuilder(
            rcloneExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            credentialResolver: RepositoryCredentialResolver(
                loadSecret: { _ in "" },
                saveSecret: { _, _ in },
                deleteSecret: { _ in }
            ),
            baseEnvironment: [:]
        )

        XCTAssertThrowsError(try builder.configuration(for: repository)) { error in
            XCTAssertEqual(
                error as? TimeMachineRcloneError,
                .unsupportedBackend(.rest)
            )
        }
    }

    func testRcloneTransportRejectsInvalidPathBeforeStartingAProcess() throws {
        let runner = RecordingTimeMachineRunner()
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )

        XCTAssertThrowsError(try transport.readObject(at: "objects/bad\0suffix")) {
            XCTAssertEqual(
                $0 as? TimeMachineRcloneError,
                .invalidObjectPath("objects/bad\0suffix")
            )
        }
        XCTAssertTrue(runner.snapshot().isEmpty)
    }

    func testProcessRunnerStopsCommandAtConfiguredDeadline() throws {
        let runner = TimeMachineBinaryProcessRunner(terminationGracePeriod: 0.05)
        let startedAt = Date()

        XCTAssertThrowsError(
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                environment: [:],
                standardInput: nil,
                maximumOutputBytes: 1_024,
                maximumRuntime: 0.05
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineBinaryProcessError,
                .timedOut(executable: "sleep", seconds: 1)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testProcessRunnerOverwritesAReusableOutputAllocationInPlace() throws {
        let byteCount = 1_048_576
        let runner = TimeMachineBinaryProcessRunner()
        var output = Data(repeating: 0xA5, count: byteCount)
        let originalAddress = output.withUnsafeBytes {
            UInt(bitPattern: $0.baseAddress)
        }

        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", String(byteCount), "/dev/zero"],
            environment: [:],
            standardInput: nil,
            maximumOutputBytes: byteCount,
            maximumRuntime: 5,
            reusingStandardOutput: &output
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(output.count, byteCount)
        XCTAssertEqual(output.first, 0)
        XCTAssertEqual(
            output.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) },
            originalAddress
        )
    }

    func testBatchPublishUsesImmutableCopyAndDownloadedOneWayVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-rclone-batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chunkURL = root.appendingPathComponent("dirty-chunk")
        try Data("chunk".utf8).write(to: chunkURL)
        let runner = RecordingTimeMachineRunner()
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )

        try transport.writeObjectsIfAbsent([
            TimeMachineRemoteObjectWrite(
                path: "namespace/blobs/chunk",
                payload: .file(chunkURL)
            ),
            TimeMachineRemoteObjectWrite(
                path: "namespace/blobs/shard",
                payload: .data(Data("shard".utf8))
            )
        ])

        let calls = runner.snapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("copy"))
        XCTAssertTrue(calls[0].contains("--immutable"))
        XCTAssertTrue(calls[0].contains("--checksum"))
        XCTAssertTrue(calls[0].contains("--no-traverse"))
        XCTAssertTrue(calls[1].contains("check"))
        XCTAssertTrue(calls[1].contains("--download"))
        XCTAssertTrue(calls[1].contains("--one-way"))
        XCTAssertEqual(runner.stagedFileCounts, [2, 2])
        XCTAssertFalse(runner.stagingRoots.contains { FileManager.default.fileExists(atPath: $0) })
    }

    func testReadAllowsMaximumSizedFileShard() throws {
        let runner = RecordingTimeMachineRunner(
            output: Data(repeating: 0xD1, count: 4 * 1_048_576)
        )
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )

        XCTAssertEqual(try transport.readObject(at: "namespace/shard").count, 4 * 1_048_576)
    }

    func testBatchReadUsesOneBoundedFilteredDownloadAndCleansStaging() throws {
        let objects = [
            "namespace/shards/a": Data("alpha".utf8),
            "namespace/shards/b": Data("beta".utf8)
        ]
        let runner = BatchReadTimeMachineRunner(objects: objects)
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )

        XCTAssertEqual(
            try transport.readObjects(at: objects.keys.sorted()),
            objects
        )
        let arguments = try XCTUnwrap(runner.arguments)
        XCTAssertTrue(arguments.contains("--files-from-raw"))
        XCTAssertTrue(arguments.contains("--no-traverse"))
        XCTAssertTrue(arguments.contains("--max-transfer"))
        XCTAssertTrue(arguments.contains("64Mi"))
        XCTAssertEqual(
            Set(String(decoding: try XCTUnwrap(runner.standardInput), as: UTF8.self)
                .split(separator: "\n").map(String.init)),
            Set(objects.keys)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(runner.stagingRoot))
        )
    }

    func testConfiguredBatchStagingReclaimsOneCrashResidueLeaf() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-rclone-stable-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let stale = parent
            .appendingPathComponent("read", isDirectory: true)
            .appendingPathComponent("stale", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("crash residue".utf8).write(to: stale)
        let path = "namespace/shards/current"
        let expected = Data("current".utf8)
        let runner = BatchReadTimeMachineRunner(objects: [path: expected])
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:],
                stagingDirectoryURL: parent
            ),
            runner: runner
        )

        XCTAssertEqual(try transport.readObjects(at: [path]), [path: expected])
        XCTAssertEqual(
            try XCTUnwrap(runner.stagingRoot),
            parent.appendingPathComponent("read", isDirectory: true).path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("read", isDirectory: true).path
            )
        )
    }

    func testBatchReadRejectsAnOversizedDownloadedObject() throws {
        let path = "namespace/shards/oversized"
        let runner = BatchReadTimeMachineRunner(objects: [
            path: Data(
                repeating: 0xE1,
                count: TimeMachineRepositorySettings.chunkSizeBytes + 1
            )
        ])
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )

        XCTAssertThrowsError(try transport.readObjects(at: [path])) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectSizeLimitExceeded(TimeMachineRepositorySettings.chunkSizeBytes)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(runner.stagingRoot))
        )
    }

    func testBatchPublishRejectsAnOversizedPayloadBeforeRunningRclone() throws {
        let runner = RecordingTimeMachineRunner()
        let transport = TimeMachineRcloneObjectTransport(
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                remoteRoot: "mock:root",
                environment: [:]
            ),
            runner: runner
        )
        let oversized = Data(
            repeating: 0xE2,
            count: TimeMachineRepositorySettings.chunkSizeBytes + 1
        )

        XCTAssertThrowsError(
            try transport.writeObjectsIfAbsent([
                TimeMachineRemoteObjectWrite(
                    path: "namespace/blobs/oversized",
                    payload: .data(oversized)
                )
            ])
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectSizeLimitExceeded(TimeMachineRepositorySettings.chunkSizeBytes)
            )
        }
        XCTAssertTrue(runner.snapshot().isEmpty)
    }
}

private final class BatchReadTimeMachineRunner: TimeMachineBinaryProcessRunning, @unchecked Sendable {
    private let objects: [String: Data]
    private(set) var arguments: [String]?
    private(set) var standardInput: Data?
    private(set) var stagingRoot: String?

    init(objects: [String: Data]) {
        self.objects = objects
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval
    ) throws -> TimeMachineBinaryProcessResult {
        self.arguments = arguments
        self.standardInput = standardInput
        let root = arguments.last!
        stagingRoot = root
        let requested = String(decoding: standardInput ?? Data(), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        for path in requested {
            guard let data = objects[path] else { continue }
            let url = path.split(separator: "/").reduce(URL(fileURLWithPath: root)) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return TimeMachineBinaryProcessResult(
            exitCode: 0,
            standardOutput: Data(),
            standardError: ""
        )
    }
}

private final class RecordingTimeMachineRunner: TimeMachineBinaryProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let output: Data
    private(set) var stagedFileCounts: [Int] = []
    private(set) var stagingRoots: [String] = []

    init(output: Data = Data()) {
        self.output = output
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval
    ) throws -> TimeMachineBinaryProcessResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append(arguments)
        if arguments.contains("copy") || arguments.contains("check"), arguments.count >= 2 {
            let root = arguments[arguments.count - 2]
            stagingRoots.append(root)
            let count = (try? FileManager.default.subpathsOfDirectory(atPath: root).filter { path in
                var isDirectory: ObjCBool = false
                let fullPath = URL(fileURLWithPath: root).appendingPathComponent(path).path
                return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }.count) ?? 0
            stagedFileCounts.append(count)
        }
        return TimeMachineBinaryProcessResult(
            exitCode: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    func snapshot() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
