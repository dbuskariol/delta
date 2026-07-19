import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineStoreBootstrapTests: XCTestCase {
    private let storeID = UUID(uuidString: "5142B0B8-779D-4219-A9E0-C7A6237E9AE3")!
    private let password = "correct horse battery staple"
    private let manifestKey = Data((0..<32).map(UInt8.init))

    func testBootstrapRoundTripRecoversIndependentManifestKey() throws {
        let settings = TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: "Archive",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let bootstrap = try TimeMachineStoreBootstrap.create(
            settings: settings,
            password: password,
            manifestKey: manifestKey,
            createdAt: Date(timeIntervalSince1970: 1_721_234_567.123_9)
        )
        let encoded = try TimeMachineStoreBootstrap.canonicalEncoder.encode(bootstrap)
        let decoded = try TimeMachineStoreBootstrap.canonicalDecoder.decode(
            TimeMachineStoreBootstrap.self,
            from: encoded
        )

        XCTAssertEqual(decoded.storeID, storeID)
        XCTAssertEqual(decoded.remoteNamespace, settings.remoteNamespace)
        XCTAssertEqual(decoded.kdfAlgorithm, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(decoded.kdfIterations, 600_000)
        XCTAssertEqual(decoded.wrapAlgorithm, "AES-256-GCM")
        XCTAssertEqual(
            decoded.chunkSizeBytes,
            TimeMachineRepositorySettings.sparsebundleBandSizeBytes
        )
        XCTAssertEqual(try decoded.unwrapManifestKey(password: password), manifestKey)
        XCTAssertEqual(
            try decoded.recoveredSettings(cacheLimitBytes: 67_108_864),
            settings
        )
    }

    func testWrongPasswordCannotUnwrapManifestKey() throws {
        let bootstrap = try makeBootstrap()

        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: "wrong")) {
            XCTAssertEqual(
                $0 as? TimeMachineStoreBootstrapError,
                .authenticationFailed
            )
        }
    }

    func testOversizedPasswordFailsBeforeKeyDerivation() throws {
        let oversized = String(
            repeating: "p",
            count: TimeMachineRepositorySettings.maximumDiskPasswordBytes + 1
        )
        XCTAssertThrowsError(
            try TimeMachineStoreBootstrap.create(
                settings: TimeMachineRepositorySettings(
                    storeID: storeID,
                    volumeName: "Archive"
                ),
                password: oversized,
                manifestKey: manifestKey
            )
        ) {
            XCTAssertEqual($0 as? TimeMachineStoreBootstrapError, .invalidPassword)
        }

        let bootstrap = try makeBootstrap()
        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: oversized)) {
            XCTAssertEqual($0 as? TimeMachineStoreBootstrapError, .invalidPassword)
        }
    }

    func testAuthenticatedMetadataTamperingCannotRedirectStore() throws {
        var bootstrap = try makeBootstrap()
        bootstrap.volumeName = "Forged"

        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: password)) {
            XCTAssertEqual(
                $0 as? TimeMachineStoreBootstrapError,
                .authenticationFailed
            )
        }
    }

    func testInvalidNamespaceAndExcessiveKDFWorkFailBeforeDerivation() throws {
        var bootstrap = try makeBootstrap()
        bootstrap.remoteNamespace = "delta-time-machine/v1/other"
        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: password)) {
            XCTAssertEqual($0 as? TimeMachineStoreBootstrapError, .invalidBootstrap)
        }

        bootstrap = try makeBootstrap()
        bootstrap.kdfIterations = 10_000_001
        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: password)) {
            XCTAssertEqual($0 as? TimeMachineStoreBootstrapError, .invalidBootstrap)
        }

        bootstrap = try makeBootstrap()
        bootstrap.chunkSizeBytes /= 2
        XCTAssertThrowsError(try bootstrap.unwrapManifestKey(password: password)) {
            XCTAssertEqual($0 as? TimeMachineStoreBootstrapError, .invalidBootstrap)
        }
    }

    func testTimeMachinePasswordAccountIsStableAcrossLocalRepositoryIDs() {
        let settings = TimeMachineRepositorySettings(storeID: storeID, volumeName: "Archive")
        let first = BackupRepository(
            name: "First",
            backend: .local(path: "/one"),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        let second = BackupRepository(
            name: "Second",
            backend: .local(path: "/two"),
            format: .timeMachine,
            timeMachineSettings: settings
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.keychainAccount, second.keychainAccount)
        XCTAssertEqual(
            first.keychainAccount,
            "time-machine-password-5142B0B8-779D-4219-A9E0-C7A6237E9AE3"
        )
    }

    func testBootstrapStorePublishesOnceAndSupportsFreshRecovery() throws {
        let transport = BootstrapMemoryTransport()
        let store = TimeMachineStoreBootstrapStore(
            transport: AnyTimeMachineRemoteObjectTransport(transport)
        )
        let settings = TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: "Archive",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )

        let first = try store.prepare(
            settings: settings,
            password: password,
            manifestKey: manifestKey
        )
        let retry = try store.prepare(
            settings: settings,
            password: password,
            manifestKey: manifestKey
        )
        let recovered = try store.recover(password: password)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(recovered.bootstrap, first)
        XCTAssertEqual(recovered.manifestKey, manifestKey)
        XCTAssertEqual(transport.writeCount, 1)
    }

    func testBootstrapStoreRejectsCreatingOverAnExistingStore() throws {
        let transport = BootstrapMemoryTransport()
        let store = TimeMachineStoreBootstrapStore(
            transport: AnyTimeMachineRemoteObjectTransport(transport)
        )
        _ = try store.prepare(
            settings: TimeMachineRepositorySettings(
                storeID: storeID,
                volumeName: "Archive"
            ),
            password: password,
            manifestKey: manifestKey
        )
        let different = TimeMachineRepositorySettings(
            storeID: UUID(),
            volumeName: "New Disk"
        )

        XCTAssertThrowsError(
            try store.prepare(
                settings: different,
                password: "new password",
                manifestKey: Data(repeating: 9, count: 32)
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineStoreBootstrapError,
                .existingStore(storeID)
            )
        }
        XCTAssertEqual(transport.writeCount, 1)
    }

    func testRecoveryInspectorAuthenticatesBootstrapAndSignedGenerationBeforeReturning() throws {
        let remoteURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-recovery-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let settings = TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: "Archive",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        _ = try TimeMachineStoreBootstrapStore(
            transport: AnyTimeMachineRemoteObjectTransport(transport)
        ).prepare(settings: settings, password: password, manifestKey: manifestKey)
        let generationStore = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: manifestKey,
            transport: transport
        )
        let writerID = UUID()
        let lease = try generationStore.acquireLease(ownerID: writerID)
        let committedHead = try generationStore.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: lease
        )
        try generationStore.releaseLease(lease)
        let provisional = BackupRepository(
            name: "Recovered Archive",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: TimeMachineRepositorySettings(volumeName: "Discovering")
        )
        let inspector = TimeMachineDestinationRecoveryInspector()

        XCTAssertEqual(
            try inspector.discoverBootstrap(for: provisional).storeID,
            storeID
        )
        let result = try inspector.recover(
            provisional,
            password: password,
            cacheLimitBytes: 67_108_864
        )
        XCTAssertEqual(result.settings, settings)
        XCTAssertEqual(result.manifestKey, manifestKey)
        XCTAssertEqual(result.committedGeneration, 1)
        XCTAssertEqual(
            result.committedManifestDigest,
            committedHead.signedManifest.manifestDigest
        )
    }

    private func makeBootstrap() throws -> TimeMachineStoreBootstrap {
        try TimeMachineStoreBootstrap.create(
            settings: TimeMachineRepositorySettings(
                storeID: storeID,
                volumeName: "Archive",
                imageCapacityBytes: 1_099_511_627_776,
                cacheLimitBytes: 67_108_864
            ),
            password: password,
            manifestKey: manifestKey,
            createdAt: Date(timeIntervalSince1970: 1_721_234_567)
        )
    }
}

private final class BootstrapMemoryTransport: TimeMachineRemoteObjectTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private(set) var writeCount = 0

    func readObject(at path: String) throws -> Data {
        try lock.withLock {
            guard let data = objects[path] else {
                throw TimeMachineObjectStoreError.objectNotFound(path)
            }
            return data
        }
    }

    func writeObjectIfAbsent(_ data: Data, at path: String) throws {
        try lock.withLock {
            guard objects[path] == nil else {
                throw TimeMachineObjectStoreError.objectAlreadyExists(path)
            }
            objects[path] = data
            writeCount += 1
        }
    }

    func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata] {
        lock.withLock {
            objects.compactMap { path, data in
                path.hasPrefix(prefix)
                    ? TimeMachineRemoteObjectMetadata(path: path, size: Int64(data.count))
                    : nil
            }
        }
    }

    func deleteObject(at path: String) throws {
        _ = lock.withLock { objects.removeValue(forKey: path) }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
