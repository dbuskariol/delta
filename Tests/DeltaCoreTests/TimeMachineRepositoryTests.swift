import Darwin
import Foundation
import DeltaTimeMachineIPC
import XCTest
@testable import DeltaCore

final class TimeMachineRepositoryTests: XCTestCase {
    func testGenerationContinuityNeverMovesPersistedRollbackWitnessBackward() throws {
        let repositoryID = UUID()
        let storeID = UUID()
        let state = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: storeID,
            lifecycle: .ready,
            committedGeneration: 46,
            committedManifestDigest: "digest-46"
        )
        let generation45 = generationHead(
            storeID: storeID,
            generation: 45,
            digest: "digest-45",
            parentDigest: "digest-44"
        )
        let generation46 = generationHead(
            storeID: storeID,
            generation: 46,
            digest: "digest-46",
            parentDigest: "digest-45"
        )
        let generation47 = generationHead(
            storeID: storeID,
            generation: 47,
            digest: "digest-47",
            parentDigest: "digest-46"
        )

        XCTAssertNoThrow(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation46],
                persistedState: state,
                expectedStoreID: storeID
            )
        )
        XCTAssertNoThrow(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation46, generation47],
                persistedState: state,
                expectedStoreID: storeID
            )
        )
        XCTAssertThrowsError(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation45],
                persistedState: state,
                expectedStoreID: storeID
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .remoteGenerationRollback(minimumExpected: 46, actual: 45)
            )
        }
        XCTAssertThrowsError(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [],
                persistedState: state,
                expectedStoreID: storeID
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .missingRemoteGeneration(minimumExpected: 46)
            )
        }
        XCTAssertThrowsError(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation46],
                persistedState: state,
                expectedStoreID: UUID()
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .localStoreIdentityMismatch
            )
        }
        XCTAssertThrowsError(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [
                    generationHead(
                        storeID: storeID,
                        generation: 46,
                        digest: "forked-digest-46",
                        parentDigest: "digest-45"
                    )
                ],
                persistedState: state,
                expectedStoreID: storeID
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .remoteManifestMismatch(generation: 46)
            )
        }
        XCTAssertThrowsError(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation47],
                persistedState: state,
                expectedStoreID: storeID
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .committedManifestNotRetained(generation: 46)
            )
        }

        var legacyState = state
        legacyState.committedManifestDigest = nil
        XCTAssertNoThrow(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [generation47],
                persistedState: legacyState,
                expectedStoreID: storeID
            )
        )

        let unanchored = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: storeID,
            committedGeneration: 0
        )
        XCTAssertNoThrow(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [],
                persistedState: unanchored,
                expectedStoreID: storeID
            )
        )
        XCTAssertNoThrow(
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: [],
                persistedState: nil,
                expectedStoreID: storeID
            )
        )
    }

    private func generationHead(
        storeID: UUID,
        generation: UInt64,
        digest: String,
        parentDigest: String?
    ) -> TimeMachineGenerationHead {
        let writerID = UUID()
        return TimeMachineGenerationHead(
            signedManifest: TimeMachineSignedManifest(
                manifest: TimeMachineGenerationManifest(
                    storeID: storeID,
                    generation: generation,
                    parentManifestDigest: parentDigest,
                    writerID: writerID,
                    fileShards: []
                ),
                manifestDigest: digest,
                authenticationCode: "authenticated"
            ),
            objectPath: "manifest-\(generation)-\(writerID.uuidString)-\(digest)"
        )
    }

    func testDiskBackendRejectsRemoteRollbackBeforeLeaseOrCacheMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-rollback-witness-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x71, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .ready,
                committedGeneration: 2
            )
        )
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let writerID = UUID()
        let seedLease = try store.acquireLease(ownerID: writerID)
        _ = try store.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: seedLease
        )
        try store.releaseLease(seedLease)
        XCTAssertTrue(
            try transport.listObjects(
                withPrefix: "\(settings.remoteNamespace)/leases/"
            ).isEmpty
        )

        XCTAssertThrowsError(
            try TimeMachineDiskBackend(
                repository: repository,
                database: database,
                authenticationKey: authenticationKey,
                transport: AnyTimeMachineRemoteObjectTransport(transport),
                applicationSupportURL: supportURL
            )
        ) {
            XCTAssertEqual(
                $0 as? TimeMachineGenerationContinuityError,
                .remoteGenerationRollback(minimumExpected: 2, actual: 1)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportURL.path))
        XCTAssertTrue(
            try transport.listObjects(
                withPrefix: "\(settings.remoteNamespace)/leases/"
            ).isEmpty
        )
    }

    func testDiskBackendPreservesPOSIXRenameFailureSemantics() {
        XCTAssertEqual(
            TimeMachineDiskBackend.errorNumber(
                for: TimeMachineSparseFileSessionError.invalidRename
            ),
            EINVAL
        )
        XCTAssertEqual(
            TimeMachineDiskBackend.errorNumber(
                for: TimeMachineSparseFileSessionError.renameDestinationNotEmpty
            ),
            ENOTEMPTY
        )
    }

    func testOnlyPreparedDisconnectedOrRetryableFailureStatesAllowSystemConnection() {
        let repositoryID = UUID()
        let storeID = UUID()
        func state(
            _ lifecycle: TimeMachineDestinationLifecycle,
            failure: TimeMachineDestinationFailureContext? = nil
        ) -> TimeMachineDestinationState {
            TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: lifecycle,
                lastError: failure == nil ? nil : "failure",
                lastFailureContext: failure
            )
        }

        XCTAssertTrue(state(.waitingForPermissions).allowsSystemConnection)
        XCTAssertTrue(state(.ready).allowsSystemConnection)
        XCTAssertTrue(state(.disconnected).allowsSystemConnection)
        XCTAssertTrue(state(.failed, failure: .systemConnection).allowsSystemConnection)
        XCTAssertTrue(state(.failed, failure: .systemDestinationCleanup).allowsSystemConnection)
        XCTAssertTrue(state(.failed, failure: .storageService).allowsSystemConnection)
        XCTAssertFalse(state(.failed, failure: .remotePreparation).allowsSystemConnection)
        XCTAssertFalse(state(.preparing).allowsSystemConnection)
        XCTAssertFalse(state(.disconnecting).allowsSystemConnection)
        XCTAssertFalse(state(.mounted).allowsSystemConnection)
        XCTAssertFalse(state(.needsRepair).allowsSystemConnection)
    }

    func testSoftwareUpdatesRequireAuthoritativelyDisconnectedTimeMachineDisks() {
        let repositoryID = UUID()
        let storeID = UUID()
        let policy = TimeMachineSoftwareUpdatePolicy()

        XCTAssertEqual(
            policy.readiness(states: [:], stateIsAuthoritative: false),
            .applicationStateUnavailable
        )
        XCTAssertEqual(policy.readiness(states: [:], stateIsAuthoritative: true), .ready)

        for lifecycle in [
            TimeMachineDestinationLifecycle.waitingForPermissions,
            .ready,
            .disconnected,
            .needsRepair,
            .failed
        ] {
            let state = TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: lifecycle
            )
            XCTAssertEqual(
                policy.readiness(states: [repositoryID: state], stateIsAuthoritative: true),
                .ready,
                "\(lifecycle) must not claim a live system disk"
            )
        }

        for lifecycle in [
            TimeMachineDestinationLifecycle.preparing,
            .mounted,
            .disconnecting
        ] {
            let state = TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: lifecycle
            )
            XCTAssertEqual(
                policy.readiness(states: [repositoryID: state], stateIsAuthoritative: true),
                .timeMachineDestinationsConnected([repositoryID])
            )
        }

        let residualDevice = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: storeID,
            lifecycle: .failed,
            mountPoint: "/Volumes/History",
            deviceIdentifier: "disk42"
        )
        XCTAssertEqual(
            policy.readiness(
                states: [repositoryID: residualDevice],
                stateIsAuthoritative: true
            ),
            .timeMachineDestinationsConnected([repositoryID])
        )
    }

    func testRuntimeIOFailurePreservesMountedLifecycleUntilExplicitDisconnect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-mounted-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x4A, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .mounted,
                mountPoint: "/Volumes/History",
                lastError: "Connection rollback still requires a disconnect.",
                lastFailureContext: .systemConnection
            )
        )
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let writerID = UUID()
        let lease = try store.acquireLease(ownerID: writerID)
        _ = try store.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: lease
        )
        try store.releaseLease(lease)

        do {
            let backend = try TimeMachineDiskBackend(
                repository: repository,
                database: database,
                authenticationKey: authenticationKey,
                transport: AnyTimeMachineRemoteObjectTransport(transport),
                applicationSupportURL: supportURL
            )
            let initializedState = try XCTUnwrap(
                database.fetchTimeMachineDestinationState(repositoryID: repository.id)
            )
            XCTAssertEqual(initializedState.lastFailureContext, .systemConnection)
            XCTAssertEqual(
                initializedState.lastError,
                "Connection rollback still requires a disconnect."
            )
            let systemFailureResult = backend.handle(
                request: TimeMachineDiskRequest(
                    operation: .read,
                    path: "../invalid-band",
                    offset: 0,
                    length: 1
                ),
                payload: Data()
            )
            XCTAssertNotEqual(systemFailureResult.response.errorNumber, 0)
            let preservedSystemFailure = try XCTUnwrap(
                database.fetchTimeMachineDestinationState(repositoryID: repository.id)
            )
            XCTAssertEqual(
                preservedSystemFailure.lastFailureContext,
                .systemConnection
            )
            XCTAssertEqual(
                preservedSystemFailure.lastError,
                "Connection rollback still requires a disconnect."
            )

            var connectedState = preservedSystemFailure
            connectedState.lastError = nil
            connectedState.lastFailureContext = nil
            try database.saveTimeMachineDestinationState(connectedState)
            let storageFailureResult = backend.handle(
                request: TimeMachineDiskRequest(
                    operation: .read,
                    path: "../invalid-band",
                    offset: 0,
                    length: 1
                ),
                payload: Data()
            )
            XCTAssertNotEqual(storageFailureResult.response.errorNumber, 0)
        }

        let state = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(state.lifecycle, .mounted)
        XCTAssertEqual(state.mountPoint, "/Volumes/History")
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(state.lastFailureContext, .remoteSynchronization)
    }

    func testBackendCalculatesStorageMetricsOnlyForExplicitStatusRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-status-metrics-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x3C, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let writerID = UUID()
        let lease = try store.acquireLease(ownerID: writerID)
        let seededHead = try store.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: lease
        )
        try store.releaseLease(lease)

        let backend = try TimeMachineDiskBackend(
            repository: repository,
            database: database,
            authenticationKey: authenticationKey,
            transport: AnyTimeMachineRemoteObjectTransport(transport),
            applicationSupportURL: supportURL
        )
        let witnessedState = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(witnessedState.committedGeneration, 1)
        XCTAssertEqual(
            witnessedState.committedManifestDigest,
            seededHead.signedManifest.manifestDigest
        )
        let create = backend.handle(
            request: TimeMachineDiskRequest(
                operation: .create,
                path: "history.sparsebundle/bands/0"
            ),
            payload: Data()
        ).response
        XCTAssertEqual(create.errorNumber, 0)
        XCTAssertEqual(create.generation, 1)
        XCTAssertNil(create.cleanCacheBytes)
        XCTAssertNil(create.dirtyCacheBytes)
        XCTAssertNil(create.capacityBytes)
        XCTAssertNil(create.usedBytes)

        let status = backend.handle(
            request: TimeMachineDiskRequest(operation: .status),
            payload: Data()
        ).response
        XCTAssertEqual(status.errorNumber, 0)
        XCTAssertEqual(status.generation, 1)
        XCTAssertEqual(status.cleanCacheBytes, 0)
        XCTAssertEqual(status.dirtyCacheBytes, 0)
        XCTAssertEqual(status.capacityBytes, settings.imageCapacityBytes)
        XCTAssertEqual(status.usedBytes, 0)
    }

    func testBackendDoesNotRoundTripRemoteLeaseForEveryDirtyWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-write-lease-performance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x6C, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let local = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let seedStore = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: local
        )
        let seedWriter = UUID()
        let seedLease = try seedStore.acquireLease(ownerID: seedWriter)
        _ = try seedStore.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: seedWriter,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: seedLease
        )
        try seedStore.releaseLease(seedLease)

        let counts = LockedTimeMachineTransportCounts()
        let tracked = AnyTimeMachineRemoteObjectTransport(
            read: local.readObject,
            readBatch: local.readObjects,
            writeIfAbsent: local.writeObjectIfAbsent,
            writeBatchIfAbsent: local.writeObjectsIfAbsent,
            list: { prefix in
                counts.recordList()
                return try local.listObjects(withPrefix: prefix)
            },
            delete: local.deleteObject
        )
        let backend = try TimeMachineDiskBackend(
            repository: repository,
            database: database,
            authenticationKey: authenticationKey,
            transport: tracked,
            applicationSupportURL: supportURL
        )
        let listsAfterStartup = counts.listCount

        for index in 0..<16 {
            let result = backend.handle(
                request: TimeMachineDiskRequest(
                    operation: .write,
                    path: "history.sparsebundle/bands/0",
                    offset: UInt64(index * 4),
                    payloadLength: 4
                ),
                payload: Data(repeating: UInt8(index), count: 4)
            )
            XCTAssertEqual(result.response.errorNumber, 0)
        }

        XCTAssertEqual(
            counts.listCount,
            listsAfterStartup,
            "Volatile bounded-cache writes must not perform one remote lease listing per filesystem mutation."
        )
    }

    func testBackendSpillsAtMinimumCacheInsteadOfReturningLocalENOSPC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-bounded-window-spill-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x7D, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: TimeMachineRepositorySettings.minimumCacheLimitBytes
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let seedWriter = UUID()
        let seedLease = try store.acquireLease(ownerID: seedWriter)
        _ = try store.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: seedWriter,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: seedLease
        )
        try store.releaseLease(seedLease)

        let backend = try TimeMachineDiskBackend(
            repository: repository,
            database: database,
            authenticationKey: authenticationKey,
            transport: AnyTimeMachineRemoteObjectTransport(transport),
            applicationSupportURL: supportURL
        )
        // Three complete 64 MiB windows plus one band proves the mechanism is
        // reusable; it is not a one-off escape hatch for the ninth band.
        let bandCount = 25
        for index in 0..<bandCount {
            let response = backend.handle(
                request: TimeMachineDiskRequest(
                    operation: .write,
                    path: "history.sparsebundle/bands/\(index)",
                    offset: 0,
                    payloadLength: 1
                ),
                payload: Data([0xA5])
            ).response
            XCTAssertEqual(
                response.errorNumber,
                0,
                "A valid write must spill remotely rather than expose local cache pressure."
            )
            let status = backend.handle(
                request: TimeMachineDiskRequest(operation: .status),
                payload: Data()
            ).response
            XCTAssertLessThanOrEqual(
                (status.cleanCacheBytes ?? 0) + (status.dirtyCacheBytes ?? 0),
                settings.cacheLimitBytes
            )
        }

        XCTAssertEqual(try store.loadHead()?.signedManifest.manifest.generation, 1)
        let beforeSync = backend.handle(
            request: TimeMachineDiskRequest(operation: .status),
            payload: Data()
        ).response
        XCTAssertEqual(
            beforeSync.dirtyCacheBytes,
            Int64(TimeMachineRepositorySettings.chunkSizeBytes)
        )
        XCTAssertEqual(
            beforeSync.usedBytes,
            Int64(bandCount * TimeMachineRepositorySettings.chunkSizeBytes)
        )

        let synchronized = backend.handle(
            request: TimeMachineDiskRequest(operation: .synchronize, wait: true),
            payload: Data()
        ).response
        XCTAssertEqual(synchronized.errorNumber, 0)
        XCTAssertEqual(synchronized.generation, 2)
        let head = try XCTUnwrap(store.loadHead())
        let files = try store.loadFiles(from: head)
        XCTAssertEqual(files.count, bandCount)
        XCTAssertTrue(files.allSatisfy { $0.logicalSize == 1 && $0.chunks.count == 1 })
        let firstBand = try store.readChunk(try XCTUnwrap(files.first?.chunks.first))
        XCTAssertEqual(firstBand.count, TimeMachineRepositorySettings.chunkSizeBytes)
        XCTAssertEqual(firstBand.first, 0xA5)
        XCTAssertTrue(firstBand.dropFirst().allSatisfy { $0 == 0 })
    }

    func testBackendPreservesDirtyWindowWhenRemoteSpillFailsAndRetries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-spill-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x8D, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: TimeMachineRepositorySettings.minimumCacheLimitBytes
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let local = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let seedStore = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: local
        )
        let seedWriter = UUID()
        let seedLease = try seedStore.acquireLease(ownerID: seedWriter)
        _ = try seedStore.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: seedWriter,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: seedLease
        )
        try seedStore.releaseLease(seedLease)

        let gate = LockedTimeMachineStageGate()
        let transport = AnyTimeMachineRemoteObjectTransport(
            read: local.readObject,
            readBatch: local.readObjects,
            writeIfAbsent: local.writeObjectIfAbsent,
            writeBatchIfAbsent: { objects in
                try gate.beforeBatch()
                try local.writeObjectsIfAbsent(objects)
            },
            list: local.listObjects,
            delete: local.deleteObject
        )
        let backend = try TimeMachineDiskBackend(
            repository: repository,
            database: database,
            authenticationKey: authenticationKey,
            transport: transport,
            applicationSupportURL: supportURL
        )
        for index in 0..<8 {
            XCTAssertEqual(
                backend.handle(
                    request: TimeMachineDiskRequest(
                        operation: .write,
                        path: "history.sparsebundle/bands/\(index)",
                        offset: 0,
                        payloadLength: 1
                    ),
                    payload: Data([0xB5])
                ).response.errorNumber,
                0
            )
        }
        gate.shouldFail = true
        let failed = backend.handle(
            request: TimeMachineDiskRequest(
                operation: .write,
                path: "history.sparsebundle/bands/8",
                offset: 0,
                payloadLength: 1
            ),
            payload: Data([0xB5])
        ).response
        XCTAssertEqual(failed.errorNumber, EIO)
        XCTAssertNotEqual(failed.errorNumber, ENOSPC)
        XCTAssertEqual(try seedStore.loadHead()?.signedManifest.manifest.generation, 1)
        let retained = backend.handle(
            request: TimeMachineDiskRequest(operation: .status),
            payload: Data()
        ).response
        XCTAssertEqual(retained.dirtyCacheBytes, settings.cacheLimitBytes)
        XCTAssertEqual(retained.usedBytes, settings.cacheLimitBytes)

        gate.shouldFail = false
        gate.delay = 0.05
        let retryStartedAt = Date()
        let retried = backend.handle(
            request: TimeMachineDiskRequest(
                operation: .write,
                path: "history.sparsebundle/bands/8",
                offset: 0,
                payloadLength: 1
            ),
            payload: Data([0xB5])
        )
        XCTAssertEqual(retried.response.errorNumber, 0)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(retryStartedAt),
            0.045,
            "A slow provider must apply backpressure until verified staging completes, not surface local ENOSPC."
        )
        XCTAssertEqual(gate.batchCount, 2)
        XCTAssertEqual(
            backend.handle(
                request: TimeMachineDiskRequest(operation: .synchronize, wait: true),
                payload: Data()
            ).response.errorNumber,
            0
        )
        XCTAssertEqual(try seedStore.loadHead()?.signedManifest.manifest.generation, 2)
        XCTAssertEqual(
            try seedStore.loadFiles(from: XCTUnwrap(seedStore.loadHead())).count,
            9
        )
    }

    func testBackendNoWaitSynchronizationStartsRemoteCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-no-wait-sync-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DeltaDatabase(url: root.appendingPathComponent("Delta.sqlite"))
        let remoteURL = root.appendingPathComponent("remote", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let authenticationKey = Data(repeating: 0x5D, count: 32)
        let settings = TimeMachineRepositorySettings(
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            cacheLimitBytes: 67_108_864
        )
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: remoteURL.path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let writerID = UUID()
        let lease = try store.acquireLease(ownerID: writerID)
        _ = try store.commit(
            TimeMachineGenerationCommit(
                manifest: TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                ),
                objectsByDigest: [String: Data]()
            ),
            lease: lease
        )
        try store.releaseLease(lease)
        let backend = try TimeMachineDiskBackend(
            repository: repository,
            database: database,
            authenticationKey: authenticationKey,
            transport: AnyTimeMachineRemoteObjectTransport(transport),
            applicationSupportURL: supportURL
        )
        XCTAssertEqual(
            backend.handle(
                request: TimeMachineDiskRequest(
                    operation: .write,
                    path: "history.sparsebundle/bands/0",
                    offset: 0,
                    payloadLength: 4
                ),
                payload: Data([1, 2, 3, 4])
            ).response.errorNumber,
            0
        )

        let immediate = backend.handle(
            request: TimeMachineDiskRequest(operation: .synchronize, wait: false),
            payload: Data()
        )
        XCTAssertEqual(immediate.response.errorNumber, 0)
        for _ in 0..<1_000 {
            XCTAssertEqual(
                backend.handle(
                    request: TimeMachineDiskRequest(operation: .synchronize, wait: false),
                    payload: Data()
                ).response.errorNumber,
                0
            )
        }

        let deadline = Date().addingTimeInterval(5)
        var generation: UInt64?
        repeat {
            generation = backend.handle(
                request: TimeMachineDiskRequest(operation: .status),
                payload: Data()
            ).response.generation
            if generation == 2 { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTAssertEqual(generation, 2)
        let committedHead = try XCTUnwrap(store.loadHead())
        XCTAssertEqual(committedHead.signedManifest.manifest.generation, 2)
        XCTAssertEqual(try store.loadFiles(from: committedHead).first?.logicalSize, 4)
    }

    func testTimeMachinePresentationSelectsTruthfulRecoveryActions() {
        let repositoryID = UUID()
        let storeID = UUID()

        let connectionFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "helper unavailable",
                lastFailureContext: .systemConnection
            )
        )
        XCTAssertEqual(connectionFailure.status, "Connection Failed")
        XCTAssertEqual(connectionFailure.primaryAction, .connect)
        XCTAssertEqual(connectionFailure.warningTitle, "Time Machine disk could not connect")
        XCTAssertEqual(connectionFailure.warningSymbol, "externaldrive.badge.xmark")

        let legacyFullDiskAccessFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "tmutil: setdestination requires Full Disk Access privileges. Add Terminal.",
                lastFailureContext: .systemConnection
            )
        )
        XCTAssertEqual(
            legacyFullDiskAccessFailure.warningMessage,
            TimeMachineSetupCommandFailurePolicy.fullDiskAccessUserMessage
        )

        let incompleteRollback = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .mounted,
                lastError: "Disconnect before trying again.",
                lastFailureContext: .systemConnection
            )
        )
        XCTAssertEqual(incompleteRollback.status, "Disconnect Required")
        XCTAssertEqual(
            incompleteRollback.warningTitle,
            "Time Machine connection cleanup is incomplete"
        )
        XCTAssertEqual(incompleteRollback.warningSymbol, "eject.fill")
        XCTAssertTrue(incompleteRollback.isMounted)

        let residualMountWithoutDestination = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .mounted,
                mountSessionID: UUID(),
                mountPoint: "/Volumes/History",
                diskImagePath: "History.sparsebundle",
                deviceIdentifier: "disk42s1"
            )
        )
        XCTAssertEqual(residualMountWithoutDestination.status, "Connection Incomplete")
        XCTAssertEqual(residualMountWithoutDestination.primaryAction, .none)
        XCTAssertEqual(
            residualMountWithoutDestination.warningTitle,
            "Time Machine connection is incomplete"
        )
        XCTAssertEqual(residualMountWithoutDestination.warningSymbol, "eject.fill")
        XCTAssertTrue(residualMountWithoutDestination.isMounted)

        let readyForBackup = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: storeID,
            lifecycle: .mounted,
            mountSessionID: UUID(),
            mountPoint: "/Volumes/History",
            diskImagePath: "History.sparsebundle",
            deviceIdentifier: "disk42s1",
            timeMachineDestinationID: UUID().uuidString
        )
        XCTAssertTrue(readyForBackup.isReadyForBackup)
        XCTAssertEqual(
            TimeMachineDestinationPresentation.make(state: readyForBackup).primaryAction,
            .backUpNow
        )

        let disconnecting = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .disconnecting
            )
        )
        XCTAssertEqual(disconnecting.status, "Disconnecting")
        XCTAssertEqual(disconnecting.primaryAction, .none)
        XCTAssertTrue(disconnecting.isMounted)

        let preparationFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "generation missing",
                lastFailureContext: .remotePreparation
            )
        )
        XCTAssertEqual(preparationFailure.status, "Needs Repair")
        XCTAssertEqual(preparationFailure.primaryAction, .repair)

        let verificationFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "Restore a known-good provider version, then check again.",
                lastFailureContext: .remoteVerification
            )
        )
        XCTAssertEqual(verificationFailure.status, "Verification Failed")
        XCTAssertEqual(verificationFailure.primaryAction, .checkRemoteStorage)
        XCTAssertEqual(verificationFailure.warningTitle, "Time Machine verification failed")

        let availabilityFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "Reconnect the drive, then check again.",
                lastFailureContext: .remoteAvailability
            )
        )
        XCTAssertEqual(availabilityFailure.status, "Storage Unavailable")
        XCTAssertEqual(availabilityFailure.primaryAction, .checkRemoteStorage)
        XCTAssertEqual(
            availabilityFailure.warningTitle,
            "Time Machine storage is unavailable"
        )
        XCTAssertEqual(availabilityFailure.warningSymbol, "externaldrive.badge.xmark")

        let synchronizationFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .mounted,
                mountPoint: "/Volumes/History",
                lastError: "remote offline",
                lastFailureContext: .remoteSynchronization
            )
        )
        XCTAssertEqual(synchronizationFailure.status, "Reconnecting")
        XCTAssertEqual(synchronizationFailure.primaryAction, .none)
        XCTAssertTrue(synchronizationFailure.isMounted)

        let disconnectionFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .mounted,
                mountPoint: "/Volumes/History",
                lastError: "disk busy",
                lastFailureContext: .systemDisconnection
            )
        )
        XCTAssertEqual(disconnectionFailure.status, "Disconnect Failed")
        XCTAssertEqual(disconnectionFailure.warningTitle, "Time Machine disk is still connected")
        XCTAssertEqual(disconnectionFailure.warningSymbol, "eject.fill")
        XCTAssertEqual(disconnectionFailure.primaryAction, .none)

        let persistenceFailure = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .mounted,
                mountPoint: "/Volumes/History",
                lastError: "The disk is connected, but its state was not saved.",
                lastFailureContext: .systemStatePersistence
            )
        )
        XCTAssertEqual(persistenceFailure.status, "Connected — Needs Attention")
        XCTAssertEqual(persistenceFailure.warningTitle, "Time Machine disk state was not saved")
        XCTAssertTrue(persistenceFailure.isMounted)
        XCTAssertEqual(persistenceFailure.primaryAction, .none)

        let destinationCleanup = TimeMachineDestinationPresentation.make(
            state: TimeMachineDestinationState(
                repositoryID: repositoryID,
                storeID: storeID,
                lifecycle: .failed,
                lastError: "Reconnect, then disconnect again.",
                lastFailureContext: .systemDestinationCleanup
            )
        )
        XCTAssertEqual(destinationCleanup.status, "Cleanup Needed")
        XCTAssertEqual(destinationCleanup.primaryAction, .connect)
        XCTAssertEqual(destinationCleanup.warningTitle, "Remove the old Time Machine destination")
    }

    func testBackupReadinessRequiresEveryAuthoritativeSystemField() {
        let repositoryID = UUID()
        let storeID = UUID()
        let mountSessionID = UUID()
        let destinationID = UUID().uuidString
        let complete = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: storeID,
            lifecycle: .mounted,
            mountSessionID: mountSessionID,
            mountPoint: "/Volumes/History",
            diskImagePath: "History.sparsebundle",
            deviceIdentifier: "disk42s1",
            timeMachineDestinationID: destinationID
        )
        XCTAssertTrue(complete.isReadyForBackup)

        var incompleteStates: [TimeMachineDestinationState] = []
        var missingSession = complete
        missingSession.mountSessionID = nil
        incompleteStates.append(missingSession)
        var missingMount = complete
        missingMount.mountPoint = nil
        incompleteStates.append(missingMount)
        var missingImage = complete
        missingImage.diskImagePath = nil
        incompleteStates.append(missingImage)
        var missingDevice = complete
        missingDevice.deviceIdentifier = nil
        incompleteStates.append(missingDevice)
        var missingDestination = complete
        missingDestination.timeMachineDestinationID = nil
        incompleteStates.append(missingDestination)
        var malformedDestination = complete
        malformedDestination.timeMachineDestinationID = "not-a-destination-id"
        incompleteStates.append(malformedDestination)
        var pendingFailure = complete
        pendingFailure.lastFailureContext = .systemConnection
        incompleteStates.append(pendingFailure)
        var failedLifecycle = complete
        failedLifecycle.lifecycle = .failed
        incompleteStates.append(failedLifecycle)

        for state in incompleteStates {
            XCTAssertFalse(state.isReadyForBackup)
            XCTAssertNotEqual(
                TimeMachineDestinationPresentation.make(state: state).primaryAction,
                .backUpNow
            )
        }
    }

    func testStorageFailurePresentationKeepsTechnicalObjectIdentityInActivityOnly() {
        let missingPath = "delta-time-machine/v1/store/blobs/sha256/af/secret-digest"
        let missingMessage = TimeMachineDestinationFailurePresentation.userMessage(
            for: TimeMachineObjectStoreError.objectNotFound(missingPath)
        )
        XCTAssertFalse(missingMessage.contains(missingPath))
        XCTAssertFalse(missingMessage.contains("sha256"))
        XCTAssertTrue(missingMessage.contains("Restore"))
        XCTAssertTrue(missingMessage.contains("check"))

        let integrityMessage = TimeMachineDestinationFailurePresentation.userMessage(
            for: TimeMachineObjectStoreError.invalidObjectDigest(
                expected: "expected-private-object-digest",
                actual: "actual-private-object-digest"
            )
        )
        XCTAssertFalse(integrityMessage.contains("expected-private-object-digest"))
        XCTAssertFalse(integrityMessage.contains("actual-private-object-digest"))
        XCTAssertTrue(integrityMessage.contains("integrity verification"))

        let localUnavailable = TimeMachineObjectStoreError.localDestinationUnavailable
        XCTAssertEqual(
            TimeMachineDestinationFailurePresentation.context(
                forRemoteVerificationError: localUnavailable
            ),
            .remoteAvailability
        )
        let unavailableMessage = TimeMachineDestinationFailurePresentation.userMessage(
            for: localUnavailable
        )
        XCTAssertTrue(unavailableMessage.contains("Reconnect"))
        XCTAssertTrue(unavailableMessage.contains("check"))
        XCTAssertEqual(
            TimeMachineDestinationFailurePresentation.context(
                forRemoteVerificationError: TimeMachineRcloneError.commandFailed(
                    exitCode: 1,
                    message: "provider rejected a secret-bearing request"
                )
            ),
            .remoteAvailability
        )
        let remoteUnavailable = TimeMachineDestinationFailurePresentation.userMessage(
            for: TimeMachineRcloneError.commandFailed(
                exitCode: 1,
                message: "provider rejected a secret-bearing request"
            )
        )
        XCTAssertFalse(remoteUnavailable.contains("secret-bearing"))
        XCTAssertTrue(remoteUnavailable.contains("credentials"))
    }

    func testLegacyTimeMachineStateDefaultsMissingFailureContextToNil() throws {
        let state = TimeMachineDestinationState(
            repositoryID: UUID(),
            storeID: UUID(),
            lifecycle: .disconnected
        )
        let encoded = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastFailureContext")
        object.removeValue(forKey: "committedManifestDigest")

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TimeMachineDestinationState.self, from: legacyPayload)

        XCTAssertNil(decoded.lastFailureContext)
        XCTAssertNil(decoded.committedManifestDigest)
        XCTAssertTrue(decoded.allowsSystemConnection)
    }

    func testMountedDestinationRejectsOfflineVerificationAndRepair() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-maintenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .mounted
            )
        )
        let manager = TimeMachineDestinationManager(database: database)

        XCTAssertThrowsError(try manager.checkRemoteStore(repository)) {
            XCTAssertEqual(
                $0 as? TimeMachineDestinationManagerError,
                .requiresDisconnectedDisk
            )
        }
        XCTAssertThrowsError(try manager.prepareRemoteStore(repository)) {
            XCTAssertEqual(
                $0 as? TimeMachineDestinationManagerError,
                .requiresDisconnectedDisk
            )
        }
        XCTAssertTrue(try database.fetchJobRuns(limit: 10).isEmpty)
    }

    func testManagerEnforcesConnectionAndDisconnectionLifecycleBeforeHelperWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-system-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        let lockManager = RepositoryJobLockManager {
            directory.appendingPathComponent("locks", isDirectory: true)
        }
        let manager = TimeMachineDestinationManager(
            database: database,
            lockManager: lockManager,
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            }
        )

        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .needsRepair
            )
        )
        XCTAssertThrowsError(try manager.connectSystemDisk(repository)) {
            XCTAssertEqual(
                $0 as? TimeMachineDestinationManagerError,
                .destinationNotReadyForConnection
            )
        }

        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .disconnected
            )
        )
        XCTAssertThrowsError(try manager.disconnectSystemDisk(repository)) {
            XCTAssertEqual(
                $0 as? TimeMachineDestinationManagerError,
                .destinationNotConnected
            )
        }
        XCTAssertTrue(try database.fetchJobRuns(limit: 10).isEmpty)
    }

    func testOrdinaryDisconnectPreservesSavedMacOSDestinationIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-preserved-destination-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(
            url: directory.appendingPathComponent("Delta.sqlite")
        )
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        let destinationID = "7858C893-96F4-44E6-9A39-172F200D3D1E"
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .mounted,
                mountSessionID: UUID(),
                mountPoint: "/Volumes/History",
                deviceIdentifier: "disk42s1",
                timeMachineDestinationID: destinationID
            )
        )
        let manager = TimeMachineDestinationManager(
            database: database,
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            },
            userDiskController: SuccessfulTimeMachineUserDiskController()
        )

        let job = try manager.disconnectSystemDisk(repository)
        let state = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )

        XCTAssertEqual(job.status, .succeeded)
        XCTAssertEqual(state.lifecycle, .disconnected)
        XCTAssertEqual(state.timeMachineDestinationID, destinationID)
        XCTAssertNil(state.mountSessionID)
        XCTAssertNil(state.mountPoint)
        XCTAssertNil(state.deviceIdentifier)
        XCTAssertNil(state.lastError)
    }

    func testManagerSerializesSystemConnectionWithDestinationWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-system-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .ready
            )
        )
        let lockManager = RepositoryJobLockManager {
            directory.appendingPathComponent("locks", isDirectory: true)
        }
        let heldLock = try XCTUnwrap(lockManager.acquire(repositoryID: repository.id))
        try withExtendedLifetime(heldLock) {
            let manager = TimeMachineDestinationManager(
                database: database,
                lockManager: lockManager,
                systemOperationLockManager: TimeMachineSystemOperationLockManager {
                    directory.appendingPathComponent("system-locks", isDirectory: true)
                }
            )
            XCTAssertThrowsError(try manager.connectSystemDisk(repository)) {
                XCTAssertEqual(
                    $0 as? TimeMachineDestinationManagerError,
                    .destinationBusy
                )
            }
        }
        XCTAssertTrue(try database.fetchJobRuns(limit: 10).isEmpty)
    }

    func testManagerPreservesStorageServiceStartupFailureWithoutWaitingForSocketTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-service-startup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .ready
            )
        )
        let manager = TimeMachineDestinationManager(
            database: database,
            lockManager: RepositoryJobLockManager {
                directory.appendingPathComponent("repository-locks", isDirectory: true)
            },
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            }
        )
        let connection = Task.detached {
            do {
                _ = try manager.connectSystemDisk(repository)
                return nil as TimeMachineDestinationManagerError?
            } catch {
                return error as? TimeMachineDestinationManagerError
            }
        }

        var observedPreparing = false
        for _ in 0..<100 {
            if try database.fetchTimeMachineDestinationState(
                repositoryID: repository.id
            )?.lifecycle == .preparing {
                observedPreparing = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(observedPreparing)
        var serviceFailure = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        serviceFailure.lifecycle = .failed
        serviceFailure.lastError = "The saved manifest key is unavailable without interaction."
        serviceFailure.lastFailureContext = .storageService
        serviceFailure.updatedAt = Date()
        try database.saveTimeMachineDestinationState(serviceFailure)

        let result = await connection.value

        XCTAssertEqual(
            result,
            .storageServiceUnavailable(
                "The saved manifest key is unavailable without interaction."
            )
        )
        let finalState = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(finalState.lifecycle, .failed)
        XCTAssertEqual(finalState.lastFailureContext, .storageService)
        XCTAssertEqual(
            finalState.lastError,
            "The saved manifest key is unavailable without interaction."
        )
    }

    func testInterruptedConnectionRecoveryRequiresReleasedDestinationLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-interrupted-connection-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            startedAt: startedAt,
            message: "Connecting the native Time Machine disk."
        )
        try database.saveRepository(repository)
        try database.saveJobRun(job)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .preparing,
                updatedAt: startedAt
            )
        )
        let lockManager = TimeMachineSystemOperationLockManager {
            directory.appendingPathComponent("locks", isDirectory: true)
        }
        let manager = TimeMachineDestinationManager(
            database: database,
            lockManager: RepositoryJobLockManager {
                directory.appendingPathComponent("repository-locks", isDirectory: true)
            },
            systemOperationLockManager: lockManager
        )
        let heldLock = try XCTUnwrap(lockManager.acquire(repositoryID: repository.id))

        let recovered = try withExtendedLifetime(heldLock) {
            try manager.recoverInterruptedSystemOperations(
                now: Date(timeIntervalSince1970: 2_000)
            )
        }

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(
            try database.fetchTimeMachineDestinationState(repositoryID: repository.id)?.lifecycle,
            .preparing
        )
        XCTAssertEqual(try database.fetchJobRuns(limit: 10).first?.status, .running)
        XCTAssertTrue(try database.fetchEvents(limit: 10).isEmpty)
    }

    func testPersistedMountedStateIsNotTrustedWhenMacOSStackIsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-stale-mounted-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        try database.saveRepository(repository)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .mounted,
                mountPoint: "/Volumes/History",
                diskImagePath: "History.sparsebundle",
                deviceIdentifier: "disk42s1",
                timeMachineDestinationID: "BE24DD67-7B3A-458B-A76E-D080ADAA0047"
            )
        )
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let manager = TimeMachineDestinationManager(
            database: database,
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            },
            userDiskController: TimeMachineUserDiskController(
                applicationSupportURL: directory.appendingPathComponent(
                    "application-support",
                    isDirectory: true
                )
            )
        )

        let reconciled = try manager.reconcileMountedSystemStates(now: observedAt)

        let state = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(reconciled, [state])
        XCTAssertEqual(state.lifecycle, .failed)
        XCTAssertNil(state.mountPoint)
        XCTAssertNil(state.deviceIdentifier)
        XCTAssertNil(state.timeMachineDestinationID)
        XCTAssertEqual(state.lastFailureContext, .systemConnection)
        XCTAssertEqual(
            state.lastError,
            TimeMachineDestinationManagerError.systemDiskNoLongerConnected
                .localizedDescription
        )
        XCTAssertEqual(state.updatedAt, observedAt)
        XCTAssertEqual(try database.fetchEvents(limit: 10).count, 1)
        XCTAssertTrue(try manager.reconcileMountedSystemStates().isEmpty)
    }

    func testInterruptedConnectionRecoveryUsesObservedAbsentSystemState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-interrupted-connection-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = Date(timeIntervalSince1970: 2_000)
        let job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            startedAt: startedAt,
            message: "Connecting the native Time Machine disk."
        )
        try database.saveRepository(repository)
        try database.saveJobRun(job)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .preparing,
                diskImagePath: "History.sparsebundle",
                updatedAt: startedAt
            )
        )
        let manager = TimeMachineDestinationManager(
            database: database,
            lockManager: RepositoryJobLockManager {
                directory.appendingPathComponent("repository-locks", isDirectory: true)
            },
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            }
        )

        let recovered = try manager.recoverInterruptedSystemOperations(now: recoveredAt)

        let state = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(recovered, [state])
        XCTAssertEqual(state.lifecycle, .failed)
        XCTAssertEqual(state.diskImagePath, "History.sparsebundle")
        XCTAssertEqual(state.lastFailureContext, .systemConnection)
        XCTAssertEqual(
            state.lastError,
            TimeMachineDestinationManagerError.systemDiskNoLongerConnected.localizedDescription
        )
        XCTAssertEqual(state.updatedAt, recoveredAt)

        let recoveredJob = try XCTUnwrap(
            database.fetchJobRuns(limit: 10).first { $0.id == job.id }
        )
        XCTAssertEqual(recoveredJob.status, .cancelled)
        XCTAssertEqual(recoveredJob.finishedAt, recoveredAt)
        XCTAssertTrue(recoveredJob.message?.contains("disk is not connected") == true)
        let logs = try database.fetchJobLogs(jobID: job.id, limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.stream, .standardError)
        XCTAssertEqual(logs.first?.date, recoveredAt)
        let events = try database.fetchEvents(limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].message.contains("Remote History"))
        XCTAssertTrue(events[0].message.contains("no system disk remains"))

        XCTAssertTrue(
            try manager.recoverInterruptedSystemOperations(
                now: Date(timeIntervalSince1970: 3_000)
            ).isEmpty
        )
        XCTAssertEqual(try database.fetchJobLogs(jobID: job.id, limit: 10).count, 1)
        XCTAssertEqual(try database.fetchEvents(limit: 10).count, 1)
    }

    func testInterruptedDisconnectionRecoveryAcceptsObservedCleanAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-interrupted-disconnection-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DeltaDatabase(url: directory.appendingPathComponent("Delta.sqlite"))
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let repository = BackupRepository(
            name: "Remote History",
            backend: .local(path: directory.appendingPathComponent("remote").path),
            format: .timeMachine,
            timeMachineSettings: settings
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = Date(timeIntervalSince1970: 2_000)
        let job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            startedAt: startedAt,
            message: "Disconnecting the Time Machine disk."
        )
        try database.saveRepository(repository)
        try database.saveJobRun(job)
        try database.saveTimeMachineDestinationState(
            TimeMachineDestinationState(
                repositoryID: repository.id,
                storeID: settings.storeID,
                lifecycle: .disconnecting,
                mountPoint: "/Volumes/History",
                deviceIdentifier: "disk42",
                timeMachineDestinationID: "D28FBAF2-C175-4051-8809-5B21024A620A",
                updatedAt: startedAt
            )
        )
        let manager = TimeMachineDestinationManager(
            database: database,
            lockManager: RepositoryJobLockManager {
                directory.appendingPathComponent("repository-locks", isDirectory: true)
            },
            systemOperationLockManager: TimeMachineSystemOperationLockManager {
                directory.appendingPathComponent("system-locks", isDirectory: true)
            }
        )

        let recovered = try manager.recoverInterruptedSystemOperations(now: recoveredAt)

        let state = try XCTUnwrap(
            database.fetchTimeMachineDestinationState(repositoryID: repository.id)
        )
        XCTAssertEqual(recovered, [state])
        XCTAssertEqual(state.lifecycle, .disconnected)
        XCTAssertNil(state.mountPoint)
        XCTAssertNil(state.deviceIdentifier)
        XCTAssertNil(state.timeMachineDestinationID)
        XCTAssertNil(state.lastFailureContext)
        XCTAssertNil(state.lastError)
        let recoveredJob = try XCTUnwrap(
            database.fetchJobRuns(limit: 10).first { $0.id == job.id }
        )
        XCTAssertEqual(recoveredJob.status, .cancelled)
        XCTAssertEqual(recoveredJob.finishedAt, recoveredAt)
        XCTAssertTrue(recoveredJob.message?.contains("macOS now confirms") == true)
        XCTAssertEqual(try database.fetchJobLogs(jobID: job.id, limit: 10).count, 1)
        let events = try database.fetchEvents(limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].message.contains("reconciled as disconnected"))
    }

    func testExistingRepositoryPayloadDefaultsToDeltaFormat() throws {
        let repository = BackupRepository(name: "Existing", backend: .custom(repository: "local:/existing"))
        let encoded = try JSONEncoder().encode(repository)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "format")
        object.removeValue(forKey: "timeMachineSettings")

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BackupRepository.self, from: legacyPayload)

        XCTAssertEqual(decoded.format, .delta)
        XCTAssertNil(decoded.timeMachineSettings)
    }

    func testTimeMachineRepositoryCreatesStableRemoteNamespaceAndManifestAccount() {
        let storeID = UUID(uuidString: "5142B0B8-779D-4219-A9E0-C7A6237E9AE3")!
        let settings = TimeMachineRepositorySettings(storeID: storeID, volumeName: "Archive")
        let repository = BackupRepository(
            name: "Archive",
            backend: .local(path: "/Volumes/Archive"),
            format: .timeMachine,
            timeMachineSettings: settings
        )

        XCTAssertEqual(repository.format, .timeMachine)
        XCTAssertEqual(
            repository.timeMachineSettings?.remoteNamespace,
            "delta-time-machine/v1/5142b0b8-779d-4219-a9e0-c7a6237e9ae3"
        )
        XCTAssertEqual(
            repository.timeMachineSettings?.manifestKeychainAccount,
            "time-machine-manifest-5142B0B8-779D-4219-A9E0-C7A6237E9AE3"
        )
    }

    func testValidatorAcceptsObjectCapableTimeMachineDestination() throws {
        var settings = TimeMachineRepositorySettings(volumeName: "  Mac History  ")
        settings.imageCapacityBytes = 1_099_511_627_776
        settings.cacheLimitBytes = 536_870_912

        let result = try BackupRepositoryValidator().validate(
            name: "Off-site Mac",
            backend: .s3(
                endpoint: "https://s3.example.com",
                bucket: "backups",
                path: "mac",
                region: "ap-southeast-2"
            ),
            format: .timeMachine,
            timeMachineSettings: settings
        )

        XCTAssertEqual(result.format, .timeMachine)
        XCTAssertEqual(result.timeMachineSettings?.volumeName, "Mac History")
    }

    func testValidatorRejectsResticRESTForTimeMachineWithoutWeakeningDeltaFormat() throws {
        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "REST",
                backend: .rest(url: "https://backup.example.com"),
                format: .timeMachine
            )
        ) { error in
            XCTAssertEqual(
                error as? BackupRepositoryValidationError,
                .timeMachineUnsupportedBackend(.rest)
            )
        }

        let delta = try BackupRepositoryValidator().validate(
            name: "REST",
            backend: .rest(url: "https://backup.example.com")
        )
        XCTAssertEqual(delta.format, .delta)
        XCTAssertNil(delta.timeMachineSettings)
    }

    func testValidatorRejectsCacheLargerThanImage() {
        let settings = TimeMachineRepositorySettings(
            volumeName: "Mac History",
            imageCapacityBytes: 536_870_912,
            cacheLimitBytes: 1_073_741_824
        )

        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Local",
                backend: .sftp(host: "nas.local", path: "/backups", username: nil, port: nil, identityFilePath: nil),
                format: .timeMachine,
                timeMachineSettings: settings
            )
        ) { error in
            XCTAssertEqual(
                error as? BackupRepositoryValidationError,
                .invalidTimeMachineCacheLimit(1_073_741_824)
            )
        }
    }

    func testValidatorRequiresEnoughCacheForCrossBandWrites() {
        let tooSmall = TimeMachineRepositorySettings.minimumCacheLimitBytes - 1
        let settings = TimeMachineRepositorySettings(
            volumeName: "Mac History",
            imageCapacityBytes: 536_870_912,
            cacheLimitBytes: tooSmall
        )

        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Local",
                backend: .local(path: FileManager.default.temporaryDirectory.path),
                format: .timeMachine,
                timeMachineSettings: settings
            )
        ) { error in
            XCTAssertEqual(
                error as? BackupRepositoryValidationError,
                .invalidTimeMachineCacheLimit(tooSmall)
            )
        }
    }

    func testValidatorRejectsCacheEqualToImage() {
        let settings = TimeMachineRepositorySettings(
            volumeName: "Mac History",
            imageCapacityBytes: 536_870_912,
            cacheLimitBytes: 536_870_912
        )

        XCTAssertThrowsError(
            try BackupRepositoryValidator().validate(
                name: "Local",
                backend: .local(path: FileManager.default.temporaryDirectory.path),
                format: .timeMachine,
                timeMachineSettings: settings
            )
        ) { error in
            XCTAssertEqual(
                error as? BackupRepositoryValidationError,
                .invalidTimeMachineCacheLimit(536_870_912)
            )
        }
    }

    func testTimeMachineValidationMessagesUseBinaryUnitsMatchingEditor() {
        XCTAssertEqual(
            BackupRepositoryValidationError.invalidTimeMachineImageCapacity(1).errorDescription,
            "Choose a Time Machine disk capacity from 256 MiB to 64 TiB. The entered byte count is 1."
        )
        XCTAssertEqual(
            BackupRepositoryValidationError.invalidTimeMachineCacheLimit(1).errorDescription,
            "Choose a Time Machine cache from 64 MiB to less than the disk capacity. The entered byte count is 1."
        )
    }
}

private struct SuccessfulTimeMachineUserDiskController: TimeMachineUserDiskControlling {
    func connect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        encryptionPassword: Data
    ) throws -> TimeMachineSetupResult {
        TimeMachineSetupResult()
    }

    func disconnect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws {}

    func observe(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws -> TimeMachineSystemDiskObservation {
        .unknown
    }
}

private final class LockedTimeMachineTransportCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var lists = 0

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lists
    }

    func recordList() {
        lock.lock()
        lists += 1
        lock.unlock()
    }
}

private final class LockedTimeMachineStageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failureEnabled = false
    private var batches = 0
    private var batchDelay: TimeInterval = 0

    var shouldFail: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failureEnabled
        }
        set {
            lock.lock()
            failureEnabled = newValue
            lock.unlock()
        }
    }

    var batchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    var delay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return batchDelay
        }
        set {
            lock.lock()
            batchDelay = max(0, newValue)
            lock.unlock()
        }
    }

    func beforeBatch() throws {
        lock.lock()
        batches += 1
        let shouldFail = failureEnabled
        let delay = batchDelay
        lock.unlock()
        if shouldFail {
            throw POSIXError(.EIO)
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
    }
}
