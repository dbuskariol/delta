import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineRcloneIntegrationTests: XCTestCase {
    func testRealLocalBackendGenerationLifecycleAndCorruptionDetection() throws {
        let fixture = try RealRcloneFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let storeID = UUID()
        let writerID = UUID()
        let namespace = "delta-time-machine/v1/\(storeID.uuidString.lowercased())"
        let authenticationKey = Data(repeating: 0xA7, count: 32)
        let recoveryPassword = "rclone integration recovery password"
        let transport = TimeMachineRcloneObjectTransport(configuration: fixture.configuration)
        let settings = TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: "Delta Remote Sim",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        _ = try TimeMachineStoreBootstrapStore(
            transport: AnyTimeMachineRemoteObjectTransport(transport)
        ).prepare(
            settings: settings,
            password: recoveryPassword,
            manifestKey: authenticationKey
        )
        let store = try TimeMachineGenerationStore(
            namespace: namespace,
            storeID: storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )

        let chunk = Data((0..<TimeMachineRepositorySettings.chunkSizeBytes).map {
            UInt8(truncatingIfNeeded: $0)
        })
        let chunkDigest = TimeMachineGenerationStore.sha256Hex(chunk)
        let chunkReference = TimeMachineChunkReference(
            index: 0,
            objectDigest: chunkDigest,
            byteCount: chunk.count
        )
        let remoteFile = TimeMachineRemoteFile(
            path: "Delta Remote Sim.sparsebundle/bands/0",
            logicalSize: UInt64(chunk.count),
            chunks: [chunkReference]
        )
        let shards = try TimeMachineGenerationStore.makeFileShards(
            storeID: storeID,
            files: [remoteFile]
        )
        var objects = shards.objectsByDigest
        objects[chunkDigest] = chunk
        let manifest = TimeMachineGenerationManifest(
            storeID: storeID,
            generation: 1,
            parentManifestDigest: nil,
            writerID: writerID,
            fileShards: shards.references
        )

        let lease = try store.acquireLease(ownerID: writerID)
        let committed = try store.commit(
            TimeMachineGenerationCommit(manifest: manifest, objectsByDigest: objects),
            lease: lease
        )
        try store.releaseLease(lease)

        XCTAssertEqual(committed.signedManifest.manifest.generation, 1)
        XCTAssertEqual(try store.loadFiles(from: committed), [remoteFile])
        XCTAssertEqual(try store.readChunk(chunkReference), chunk)

        // Retrying an immutable content-addressed batch must be idempotent.
        try transport.writeObjectsIfAbsent(objects.keys.sorted().map { digest in
            TimeMachineRemoteObjectWrite(
                path: Self.objectPath(namespace: namespace, digest: digest),
                payload: .data(try XCTUnwrap(objects[digest]))
            )
        })

        let reopened = try TimeMachineGenerationStore(
            namespace: namespace,
            storeID: storeID,
            authenticationKey: authenticationKey,
            transport: TimeMachineRcloneObjectTransport(configuration: fixture.configuration)
        )
        let reopenedHead = try XCTUnwrap(reopened.loadHead())
        XCTAssertEqual(reopenedHead.signedManifest, committed.signedManifest)
        XCTAssertEqual(try reopened.loadFiles(from: reopenedHead), [remoteFile])
        let recovered = try TimeMachineStoreBootstrapStore(
            transport: AnyTimeMachineRemoteObjectTransport(
                TimeMachineRcloneObjectTransport(configuration: fixture.configuration)
            )
        ).recover(password: recoveryPassword)
        XCTAssertEqual(recovered.bootstrap.storeID, storeID)
        XCTAssertEqual(recovered.manifestKey, authenticationKey)

        let listed = try transport.listObjects(withPrefix: "\(namespace)/blobs/sha256")
        XCTAssertEqual(Set(listed.map(\.path)), Set(objects.keys.map {
            Self.objectPath(namespace: namespace, digest: $0)
        }))

        let disposablePath = "\(namespace)/probes/delete-me"
        try transport.writeObjectIfAbsent(Data("disposable".utf8), at: disposablePath)
        XCTAssertEqual(try transport.readObject(at: disposablePath), Data("disposable".utf8))
        try transport.deleteObject(at: disposablePath)
        XCTAssertThrowsError(try transport.readObject(at: disposablePath)) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectNotFound(disposablePath)
            )
        }

        // Directly corrupting the remote object proves a fresh read never trusts
        // provider success without matching the authenticated object identity.
        let chunkURL = fixture.remoteURL.appendingPathComponent(
            Self.objectPath(namespace: namespace, digest: chunkDigest)
        )
        try Data("corrupt".utf8).write(to: chunkURL, options: .atomic)
        XCTAssertThrowsError(try reopened.readChunk(chunkReference)) { error in
            guard case let .invalidObjectDigest(expected, actual) = error as? TimeMachineObjectStoreError else {
                return XCTFail("Expected invalidObjectDigest, got \(error)")
            }
            XCTAssertEqual(expected, chunkDigest)
            XCTAssertNotEqual(actual, chunkDigest)
        }
    }

    func testRealLocalBackendFailsClosedWhenRemoteRootIsNotADirectory() throws {
        let fixture = try RealRcloneFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let blockedRoot = fixture.rootURL.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedRoot)
        var configuration = fixture.configuration
        configuration.remoteRoot = "deltatest:\(blockedRoot.path)"
        let transport = TimeMachineRcloneObjectTransport(configuration: configuration)

        XCTAssertThrowsError(
            try transport.writeObjectIfAbsent(Data("payload".utf8), at: "objects/payload")
        ) { error in
            guard case let .commandFailed(exitCode, _) = error as? TimeMachineRcloneError else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
            XCTAssertNotEqual(exitCode, 0)
        }
        XCTAssertEqual(try Data(contentsOf: blockedRoot), Data("blocker".utf8))
    }

    private static func objectPath(namespace: String, digest: String) -> String {
        "\(namespace)/blobs/sha256/\(digest.prefix(2))/\(digest)"
    }
}

private struct RealRcloneFixture {
    var rootURL: URL
    var remoteURL: URL
    var configuration: TimeMachineRcloneConfiguration

    static func make() throws -> Self {
        guard ProcessInfo.processInfo.environment["DELTA_RCLONE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set DELTA_RCLONE_INTEGRATION=1 to run the real rclone lifecycle tests.")
        }
        let binaryPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RCLONE_BINARY"],
            "RCLONE_BINARY must point to Delta's verified bundled rclone."
        )
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw XCTSkip("rclone is not executable at \(binaryPath)")
        }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-rclone-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        let remoteURL = rootURL.appendingPathComponent("remote", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let temporaryURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configURL = rootURL.appendingPathComponent("rclone.conf")
        try Data().write(to: configURL, options: .atomic)

        return Self(
            rootURL: rootURL,
            remoteURL: remoteURL,
            configuration: TimeMachineRcloneConfiguration(
                executableURL: URL(fileURLWithPath: binaryPath),
                remoteRoot: "deltatest:\(remoteURL.path)",
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": homeURL.path,
                    "TMPDIR": temporaryURL.path,
                    "RCLONE_CONFIG": configURL.path,
                    "RCLONE_CONFIG_DELTATEST_TYPE": "local"
                ]
            )
        )
    }
}
