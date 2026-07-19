import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineObjectStoreTests: XCTestCase {
    func testFractionalWireDatesRemainStableAcrossLeaseAndManifestRoundTrips() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let fractionalNow = Date(timeIntervalSince1970: 1_800_000_000.123_456)
        let writerID = UUID()

        let lease = try fixture.store.acquireLease(
            ownerID: writerID,
            duration: 300,
            now: fractionalNow
        )
        try fixture.store.verifyLease(lease, now: fractionalNow)

        var commit = try fixture.commit(
            generation: 1,
            parentDigest: nil,
            writerID: writerID,
            data: Data("fractional time".utf8)
        )
        commit.manifest.createdAt = fractionalNow
        let head = try fixture.store.commit(
            commit,
            lease: lease,
            now: fractionalNow
        )

        XCTAssertEqual(try fixture.store.loadHead(), head)
        XCTAssertEqual(
            head.signedManifest.manifest.createdAt.timeIntervalSince1970,
            1_800_000_000.123,
            accuracy: 0.000_001
        )
    }

    func testLocalTransportListsWrittenObject() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.transport.writeObjectIfAbsent(Data("value".utf8), at: "one/two/value")
        XCTAssertEqual(
            try fixture.transport.listObjects(withPrefix: "one/"),
            [TimeMachineRemoteObjectMetadata(path: "one/two/value", size: 5)]
        )
    }

    func testLocalTransportRejectsOversizedObjectBeforeReadingIt() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let object = fixture.rootURL.appendingPathComponent("oversized", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: object.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: object)
        try handle.truncate(atOffset: UInt64(TimeMachineRepositorySettings.chunkSizeBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try fixture.transport.readObject(at: "oversized")) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectSizeLimitExceeded(TimeMachineRepositorySettings.chunkSizeBytes)
            )
        }
    }

    func testLocalTransportRejectsOversizedObjectBeforeWritingIt() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let oversized = Data(
            repeating: 0xA7,
            count: TimeMachineRepositorySettings.chunkSizeBytes + 1
        )

        XCTAssertThrowsError(
            try fixture.transport.writeObjectIfAbsent(oversized, at: "oversized")
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectSizeLimitExceeded(TimeMachineRepositorySettings.chunkSizeBytes)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("oversized").path))
    }

    func testCommitPublishesAuthenticatedGenerationAfterObjectsAndReadsItBack() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writerID = UUID()
        let data = Data("encrypted sparsebundle chunk".utf8)
        let commit = try fixture.commit(
            generation: 1,
            parentDigest: nil,
            writerID: writerID,
            data: data
        )

        let lease = try fixture.store.acquireLease(ownerID: writerID, now: fixture.now)
        let head = try fixture.store.commit(
            commit,
            lease: lease,
            now: fixture.now
        )

        XCTAssertEqual(head.signedManifest.manifest.generation, 1)
        XCTAssertEqual(try fixture.store.loadHead(), head)
        let files = try fixture.store.loadFiles(from: head)
        XCTAssertEqual(try fixture.store.readChunk(files[0].chunks[0]), data)
    }

    func testStagedObjectIsDurableButInvisibleUntilManifestPublication() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let ownerID = UUID()
        let lease = try fixture.store.acquireLease(
            ownerID: ownerID,
            duration: 300,
            now: fixture.now
        )
        let data = Data("staged before the synchronization barrier".utf8)
        let digest = TimeMachineGenerationStore.sha256Hex(data)

        try fixture.store.stageObjects(
            [digest: .data(data)],
            lease: lease,
            now: fixture.now
        )

        XCTAssertNil(try fixture.store.loadHead())
        XCTAssertEqual(
            try fixture.store.readChunk(
                TimeMachineChunkReference(
                    index: 0,
                    objectDigest: digest,
                    byteCount: data.count
                )
            ),
            data
        )
        XCTAssertTrue(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/manifests/"
            ).isEmpty
        )
    }

    func testGenerationPublicationWritesPayloadsInFixedRemoteBatches() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let hook = ObjectBatchHook()
        let store = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: HookedObjectTransport(base: fixture.transport, hook: hook)
        )
        let payloadSize = 1_048_576
        var files: [TimeMachineRemoteFile] = []
        var objects: [String: Data] = [:]
        for index in 0..<65 {
            let data = Data(repeating: UInt8(index), count: payloadSize)
            let digest = TimeMachineGenerationStore.sha256Hex(data)
            files.append(
                TimeMachineRemoteFile(
                    path: "Mac.sparsebundle/bands/\(String(index, radix: 16))",
                    logicalSize: UInt64(payloadSize),
                    chunks: [
                        TimeMachineChunkReference(
                            index: 0,
                            objectDigest: digest,
                            byteCount: payloadSize
                        )
                    ]
                )
            )
            objects[digest] = data
        }
        let shards = try TimeMachineGenerationStore.makeFileShards(
            storeID: fixture.storeID,
            files: files
        )
        objects.merge(shards.objectsByDigest) { _, replacement in replacement }
        let manifest = TimeMachineGenerationManifest(
            storeID: fixture.storeID,
            generation: 1,
            parentManifestDigest: nil,
            writerID: UUID(),
            createdAt: fixture.now,
            fileShards: shards.references
        )

        let head = try store.commit(
            TimeMachineGenerationCommit(
                manifest: manifest,
                objectsByDigest: objects
            )
        )

        XCTAssertEqual(head.signedManifest.manifest.generation, 1)
        XCTAssertGreaterThanOrEqual(hook.batchByteCounts.count, 2)
        XCTAssertTrue(
            hook.batchByteCounts.allSatisfy {
                $0 <= TimeMachineRepositorySettings.remoteSpillBatchBytes
            }
        )
    }

    func testLeaseLossDuringStagedUploadLeavesNoPublishedGeneration() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let hook = ObjectBatchHook()
        let transport = HookedObjectTransport(base: fixture.transport, hook: hook)
        let store = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: transport
        )
        let ownerID = UUID()
        let lease = try store.acquireLease(
            ownerID: ownerID,
            duration: 60,
            now: fixture.now
        )
        hook.action = {
            try store.releaseLease(lease)
            _ = try store.acquireLease(
                ownerID: UUID(),
                duration: 60,
                now: fixture.now.addingTimeInterval(1)
            )
        }
        let data = Data("unreferenced after lease loss".utf8)
        let digest = TimeMachineGenerationStore.sha256Hex(data)

        XCTAssertThrowsError(
            try store.stageObjects(
                [digest: .data(data)],
                lease: lease,
                now: fixture.now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .leaseLost)
        }
        XCTAssertNil(try fixture.store.loadHead())
        XCTAssertFalse(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/blobs/"
            ).isEmpty
        )
    }

    func testHeadIgnoresAuthenticatedManifestCopiedToNoncanonicalPath() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let head = try fixture.store.commit(
            try fixture.commit(
                generation: 1,
                parentDigest: nil,
                writerID: UUID(),
                data: Data("canonical".utf8)
            )
        )
        let signedData = try fixture.transport.readObject(at: head.objectPath)
        let copiedPath = "\(fixture.namespace)/manifests/00000000000000000001-00000000-0000-0000-0000-000000000000-\(String(repeating: "0", count: 64)).json"
        try fixture.transport.writeObjectIfAbsent(signedData, at: copiedPath)

        XCTAssertEqual(try fixture.store.loadHead(), head)
    }

    func testFailureBeforeManifestPublicationLeavesPreviousGenerationAuthoritative() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writerID = UUID()
        let firstData = Data("first committed chunk".utf8)
        let firstCommit = try fixture.commit(
            generation: 1,
            parentDigest: nil,
            writerID: writerID,
            data: firstData
        )
        let firstHead = try fixture.store.commit(firstCommit)

        let failingTransport = AnyTimeMachineRemoteObjectTransport(
            read: fixture.transport.readObject,
            writeIfAbsent: { data, path in
                if path.contains("/manifests/") {
                    throw POSIXError(.EIO)
                }
                try fixture.transport.writeObjectIfAbsent(data, at: path)
            },
            list: fixture.transport.listObjects,
            delete: fixture.transport.deleteObject
        )
        let failingStore = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: failingTransport
        )
        let secondData = Data("uploaded but never committed".utf8)
        let secondCommit = try fixture.commit(
            generation: 2,
            parentDigest: firstHead.signedManifest.manifestDigest,
            writerID: writerID,
            data: secondData
        )

        XCTAssertThrowsError(
            try failingStore.commit(
                secondCommit
            )
        )

        XCTAssertEqual(try fixture.store.loadHead(), firstHead)
        let blobs = try fixture.transport.listObjects(withPrefix: "\(fixture.namespace)/blobs/")
        XCTAssertEqual(blobs.count, 4, "The unreferenced chunk and metadata shard remain for conservative later garbage collection.")
    }

    func testConcurrentGenerationPublicationCreatesDetectableFork() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let firstData = Data("writer one".utf8)
        let firstCommit = try fixture.commit(
            generation: 1,
            parentDigest: nil,
            writerID: UUID(),
            data: firstData
        )
        _ = try fixture.store.commit(firstCommit)

        let listState = LockedListState()
        let racingTransport = AnyTimeMachineRemoteObjectTransport(
            read: fixture.transport.readObject,
            writeIfAbsent: fixture.transport.writeObjectIfAbsent,
            list: { prefix in
                if prefix.contains("/manifests/"), listState.consumeFirstManifestList() {
                    return []
                }
                return try fixture.transport.listObjects(withPrefix: prefix)
            },
            delete: fixture.transport.deleteObject
        )
        let racingStore = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: racingTransport
        )
        let secondData = Data("writer two".utf8)
        let secondCommit = try fixture.commit(
            generation: 1,
            parentDigest: nil,
            writerID: UUID(),
            data: secondData
        )

        XCTAssertThrowsError(
            try racingStore.commit(
                secondCommit
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .manifestForkDetected(1))
        }
        XCTAssertThrowsError(try fixture.store.loadHead()) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .manifestForkDetected(1))
        }
    }

    func testLeaseBlocksAnotherWriterAndCanBeReleased() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let firstOwner = UUID()
        let secondOwner = UUID()
        let lease = try fixture.store.acquireLease(ownerID: firstOwner, duration: 60, now: fixture.now)

        XCTAssertThrowsError(
            try fixture.store.acquireLease(ownerID: secondOwner, duration: 60, now: fixture.now)
        ) { error in
            guard case let .leaseHeld(ownerID, expiresAt) = error as? TimeMachineObjectStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(ownerID, firstOwner)
            XCTAssertEqual(expiresAt, lease.expiresAt)
        }

        try fixture.store.releaseLease(lease)
        XCTAssertNoThrow(try fixture.store.acquireLease(ownerID: secondOwner, duration: 60, now: fixture.now))
    }

    func testLeaseListingFailsClosedBeforeReadingUnboundedCandidates() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let transport = AnyTimeMachineRemoteObjectTransport(
            read: { _ in throw POSIXError(.EIO) },
            writeIfAbsent: { _, _ in XCTFail("The capped listing must fail before a write") },
            list: { prefix in
                guard prefix.hasSuffix("/leases/") else { return [] }
                return (0...1_024).map {
                    TimeMachineRemoteObjectMetadata(
                        path: "\(prefix)\($0).json",
                        size: 1
                    )
                }
            },
            delete: { _ in }
        )
        let store = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: transport
        )

        XCTAssertThrowsError(try store.acquireLease(ownerID: UUID())) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .objectListingLimitExceeded(1_024)
            )
        }
    }

    func testOversizedLeaseFailsClosedBeforeReadingIt() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let transport = AnyTimeMachineRemoteObjectTransport(
            read: { _ in
                XCTFail("An oversized lease must be rejected from metadata")
                return Data()
            },
            writeIfAbsent: { _, _ in XCTFail("No lease may be written") },
            list: { prefix in
                guard prefix.hasSuffix("/leases/") else { return [] }
                return [
                    TimeMachineRemoteObjectMetadata(
                        path: "\(prefix)oversized.json",
                        size: 64 * 1_024 + 1
                    )
                ]
            },
            delete: { _ in }
        )
        let store = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: transport
        )

        XCTAssertThrowsError(try store.acquireLease(ownerID: UUID())) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidRemoteLease)
        }
    }

    func testNoncanonicalLeaseCopyDoesNotRemainActiveAfterCanonicalRelease() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.store.acquireLease(
            ownerID: UUID(),
            duration: 60,
            now: fixture.now
        )
        let leaseObject = try XCTUnwrap(
            fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/leases/"
            ).first
        )
        let data = try fixture.transport.readObject(at: leaseObject.path)
        try fixture.transport.writeObjectIfAbsent(
            data,
            at: "\(fixture.namespace)/leases/copied.json"
        )
        try fixture.store.releaseLease(first)

        XCTAssertNoThrow(
            try fixture.store.acquireLease(
                ownerID: UUID(),
                duration: 60,
                now: fixture.now
            )
        )
    }

    func testLeaseDurationIsBoundedBeforeRemoteMutation() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(
            try fixture.store.acquireLease(
                ownerID: UUID(),
                duration: 24 * 60 * 60 + 1,
                now: fixture.now
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidRemoteLease)
        }
        XCTAssertTrue(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/leases/"
            ).isEmpty
        )
    }

    func testSameWriterReacquiresAndRenewsOrphanedLeaseAfterRestart() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let ownerID = UUID()
        let first = try fixture.store.acquireLease(
            ownerID: ownerID,
            duration: 300,
            now: fixture.now
        )
        let restartedAt = fixture.now.addingTimeInterval(10)

        let recovered = try fixture.store.acquireLease(
            ownerID: ownerID,
            duration: 300,
            now: restartedAt
        )

        XCTAssertEqual(recovered.ownerID, ownerID)
        XCTAssertNotEqual(recovered.nonce, first.nonce)
        XCTAssertGreaterThan(recovered.expiresAt, first.expiresAt)
        try fixture.store.verifyLease(recovered, now: restartedAt)
        XCTAssertThrowsError(try fixture.store.verifyLease(first, now: restartedAt)) {
            XCTAssertEqual($0 as? TimeMachineObjectStoreError, .leaseLost)
        }
    }

    func testRenewedLeaseSupersedesOldLeaseAndContinuesExclusion() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let owner = UUID()
        let lease = try fixture.store.acquireLease(ownerID: owner, duration: 60, now: fixture.now)
        let renewalTime = fixture.now.addingTimeInterval(30)

        let renewed = try fixture.store.renewLease(lease, duration: 90, now: renewalTime)

        XCTAssertGreaterThan(renewed.expiresAt, lease.expiresAt)
        XCTAssertNoThrow(try fixture.store.verifyLease(renewed, now: renewalTime))
        XCTAssertThrowsError(try fixture.store.verifyLease(lease, now: renewalTime)) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .leaseLost)
        }
        XCTAssertThrowsError(
            try fixture.store.acquireLease(
                ownerID: UUID(),
                duration: 60,
                now: renewalTime.addingTimeInterval(1)
            )
        )
    }

    func testLeaseLossDuringObjectUploadPreventsManifestPublication() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let hook = ObjectBatchHook()
        let transport = HookedObjectTransport(base: fixture.transport, hook: hook)
        let store = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: transport
        )
        let owner = UUID()
        let lease = try store.acquireLease(ownerID: owner, duration: 60, now: fixture.now)
        hook.action = {
            try store.releaseLease(lease)
            _ = try store.acquireLease(
                ownerID: UUID(),
                duration: 60,
                now: fixture.now.addingTimeInterval(1)
            )
        }

        XCTAssertThrowsError(
            try store.commit(
                fixture.commit(
                    generation: 1,
                    parentDigest: nil,
                    writerID: owner,
                    data: Data("uploaded before lease loss".utf8)
                ),
                lease: lease,
                now: fixture.now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .leaseLost)
        }
        XCTAssertTrue(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/manifests/"
            ).isEmpty
        )
        XCTAssertFalse(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/blobs/"
            ).isEmpty,
            "Uploaded immutable objects remain unreferenced for conservative cleanup."
        )
    }

    func testManifestRetentionKeepsNewestGenerationsWithoutDeletingBlobs() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        var parent: String?
        var currentHead: TimeMachineGenerationHead?
        for generation in 1...4 {
            let head = try fixture.store.commit(
                fixture.commit(
                    generation: UInt64(generation),
                    parentDigest: parent,
                    writerID: writer,
                    data: Data("generation-\(generation)".utf8)
                )
            )
            parent = head.signedManifest.manifestDigest
            currentHead = head
        }
        let blobCount = try fixture.transport.listObjects(
            withPrefix: "\(fixture.namespace)/blobs/"
        ).count

        let lease = try fixture.store.acquireLease(
            ownerID: writer,
            duration: 600,
            now: fixture.now
        )
        defer { try? fixture.store.releaseLease(lease) }
        try fixture.store.pruneManifestHistory(
            keepingNewestGenerations: 2,
            expectedHead: try XCTUnwrap(currentHead),
            lease: lease,
            now: fixture.now
        )

        let manifests = try fixture.transport.listObjects(
            withPrefix: "\(fixture.namespace)/manifests/"
        )
        XCTAssertEqual(manifests.count, 2)
        XCTAssertTrue(manifests.allSatisfy {
            $0.path.contains("00000000000000000003-")
                || $0.path.contains("00000000000000000004-")
        })
        XCTAssertEqual(try fixture.store.loadHead()?.signedManifest.manifest.generation, 4)
        XCTAssertEqual(
            try fixture.store.loadValidatedManifestHistory().map(\.signedManifest.manifest.generation),
            [3, 4],
            "An authenticated pruned prefix may begin above generation one, but its retained suffix stays contiguous."
        )
        XCTAssertEqual(
            try fixture.transport.listObjects(withPrefix: "\(fixture.namespace)/blobs/").count,
            blobCount,
            "Transport manifest compaction must not garbage-collect referenced data."
        )
    }

    func testValidatedManifestHistoryRejectsMissingIntermediateGeneration() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        var parent: String?
        var secondManifestPath: String?
        for generation in 1...3 {
            let head = try fixture.store.commit(
                fixture.commit(
                    generation: UInt64(generation),
                    parentDigest: parent,
                    writerID: writer,
                    data: Data("generation-\(generation)".utf8)
                )
            )
            if generation == 2 {
                secondManifestPath = head.objectPath
            }
            parent = head.signedManifest.manifestDigest
        }

        try fixture.transport.deleteObject(at: try XCTUnwrap(secondManifestPath))

        XCTAssertThrowsError(try fixture.store.loadValidatedManifestHistory()) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .invalidGeneration(expected: 2, actual: 3)
            )
        }
        XCTAssertEqual(
            try fixture.store.loadHead()?.signedManifest.manifest.generation,
            3,
            "The optimized head lookup alone cannot prove retained chain continuity."
        )
    }

    func testMaintenanceRefusesHeadDifferentFromAuthenticatedPreflight() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        let first = try fixture.store.commit(
            fixture.commit(
                generation: 1,
                parentDigest: nil,
                writerID: writer,
                data: Data("first".utf8)
            )
        )
        _ = try fixture.store.commit(
            fixture.commit(
                generation: 2,
                parentDigest: first.signedManifest.manifestDigest,
                writerID: writer,
                data: Data("second".utf8)
            )
        )
        var lease = try fixture.store.acquireLease(
            ownerID: writer,
            duration: 10_000,
            now: fixture.now
        )
        defer { try? fixture.store.releaseLease(lease) }

        XCTAssertThrowsError(
            try fixture.store.pruneManifestHistory(
                keepingNewestGenerations: 1,
                expectedHead: first,
                lease: lease,
                now: fixture.now
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .leaseLost)
        }
        XCTAssertEqual(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/manifests/"
            ).count,
            2
        )

        XCTAssertThrowsError(
            try fixture.store.garbageCollectUnreferencedBlobs(
                lease: &lease,
                expectedHead: first,
                gracePeriod: 0,
                now: fixture.now
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .leaseLost)
        }
        XCTAssertTrue(
            try fixture.transport.listObjects(
                withPrefix: "\(fixture.namespace)/gc/candidates/"
            ).isEmpty
        )
    }

    func testGarbageCollectionPreservesRetainedHistoryAndRequiresGracePass() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        let firstData = Data("first retained generation".utf8)
        let first = try fixture.store.commit(
            fixture.commit(
                generation: 1,
                parentDigest: nil,
                writerID: writer,
                data: firstData
            )
        )
        let secondData = Data("second current generation".utf8)
        let second = try fixture.store.commit(
            fixture.commit(
                generation: 2,
                parentDigest: first.signedManifest.manifestDigest,
                writerID: writer,
                data: secondData
            )
        )
        var lease = try fixture.store.acquireLease(
            ownerID: writer,
            duration: 10_000,
            now: fixture.now
        )
        defer { try? fixture.store.releaseLease(lease) }

        let beforePrune = try fixture.store.garbageCollectUnreferencedBlobs(
            lease: &lease,
            expectedHead: second,
            gracePeriod: 3_600,
            now: fixture.now
        )
        XCTAssertEqual(beforePrune.newlyMarkedBlobCount, 0)
        XCTAssertEqual(beforePrune.deletedBlobCount, 0)

        try fixture.store.pruneManifestHistory(
            keepingNewestGenerations: 1,
            expectedHead: second,
            lease: lease,
            now: fixture.now
        )
        let marked = try fixture.store.garbageCollectUnreferencedBlobs(
            lease: &lease,
            expectedHead: second,
            gracePeriod: 3_600,
            now: fixture.now.addingTimeInterval(1)
        )
        XCTAssertEqual(marked.newlyMarkedBlobCount, 2)
        XCTAssertEqual(marked.deletedBlobCount, 0)

        let stillWaiting = try fixture.store.garbageCollectUnreferencedBlobs(
            lease: &lease,
            expectedHead: second,
            gracePeriod: 3_600,
            now: fixture.now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(stillWaiting.deletedBlobCount, 0)

        let swept = try fixture.store.garbageCollectUnreferencedBlobs(
            lease: &lease,
            expectedHead: second,
            gracePeriod: 3_600,
            now: fixture.now.addingTimeInterval(3_602)
        )
        XCTAssertEqual(swept.deletedBlobCount, 2)
        let head = try XCTUnwrap(fixture.store.loadHead())
        let files = try fixture.store.loadFiles(from: head)
        XCTAssertEqual(try fixture.store.readChunk(files[0].chunks[0]), secondData)
    }

    func testCorruptGarbageCollectionMarkerCannotDeleteOrphanBlob() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        let head = try fixture.store.commit(
            fixture.commit(
                generation: 1,
                parentDigest: nil,
                writerID: writer,
                data: Data("current".utf8)
            )
        )
        let orphan = Data("unreferenced".utf8)
        let digest = TimeMachineGenerationStore.sha256Hex(orphan)
        let blobPath = "\(fixture.namespace)/blobs/sha256/\(digest.prefix(2))/\(digest)"
        let markerPath = "\(fixture.namespace)/gc/candidates/\(digest.prefix(2))/\(digest).json"
        try fixture.transport.writeObjectIfAbsent(orphan, at: blobPath)
        var lease = try fixture.store.acquireLease(
            ownerID: writer,
            duration: 10_000,
            now: fixture.now
        )
        defer { try? fixture.store.releaseLease(lease) }
        _ = try fixture.store.garbageCollectUnreferencedBlobs(
            lease: &lease,
            expectedHead: head,
            gracePeriod: 60,
            now: fixture.now
        )
        try fixture.transport.deleteObject(at: markerPath)
        try fixture.transport.writeObjectIfAbsent(Data("corrupt marker".utf8), at: markerPath)

        XCTAssertThrowsError(
            try fixture.store.garbageCollectUnreferencedBlobs(
                lease: &lease,
                expectedHead: head,
                gracePeriod: 60,
                now: fixture.now.addingTimeInterval(120)
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .invalidGarbageCollectionMarker
            )
        }
        XCTAssertEqual(try fixture.transport.readObject(at: blobPath), orphan)
    }

    func testUnauthenticatedHigherManifestBlocksHistoryCompaction() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let writer = UUID()
        let head = try fixture.store.commit(
            fixture.commit(
                generation: 1,
                parentDigest: nil,
                writerID: writer,
                data: Data("current".utf8)
            )
        )
        let lease = try fixture.store.acquireLease(
            ownerID: writer,
            duration: 600,
            now: fixture.now
        )
        defer { try? fixture.store.releaseLease(lease) }
        let invalidPath = "\(fixture.namespace)/manifests/00000000000000000002-\(UUID().uuidString.lowercased())-\(String(repeating: "0", count: 64)).json"
        try fixture.transport.writeObjectIfAbsent(Data("not authenticated".utf8), at: invalidPath)

        XCTAssertThrowsError(
            try fixture.store.pruneManifestHistory(
                keepingNewestGenerations: 1,
                expectedHead: head,
                lease: lease,
                now: fixture.now
            )
        )
        XCTAssertEqual(try fixture.transport.readObject(at: head.objectPath).isEmpty, false)
    }

    func testShardedManifestScalesAndRejectsCorruptedShard() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let files = (0..<5_000).map { index in
            TimeMachineRemoteFile(
                path: "Mac.sparsebundle/bands/\(String(index, radix: 16))",
                logicalSize: 0,
                chunks: []
            )
        }
        let shards = try TimeMachineGenerationStore.makeFileShards(
            storeID: fixture.storeID,
            files: files
        )
        XCTAssertGreaterThan(shards.references.count, 1)
        XCTAssertLessThanOrEqual(shards.references.count, 4_096)
        let manifest = TimeMachineGenerationManifest(
            storeID: fixture.storeID,
            generation: 1,
            parentManifestDigest: nil,
            writerID: UUID(),
            createdAt: fixture.now,
            fileShards: shards.references
        )
        let head = try fixture.store.commit(
            TimeMachineGenerationCommit(manifest: manifest, objectsByDigest: shards.objectsByDigest)
        )
        XCTAssertEqual(try fixture.store.loadFiles(from: head).count, files.count)

        let corrupted = try XCTUnwrap(shards.references.first)
        let corruptedPath = "\(fixture.namespace)/blobs/sha256/\(corrupted.objectDigest.prefix(2))/\(corrupted.objectDigest)"
        try fixture.transport.deleteObject(at: corruptedPath)
        try fixture.transport.writeObjectIfAbsent(Data("corrupt".utf8), at: corruptedPath)
        XCTAssertThrowsError(try fixture.store.loadFiles(from: head)) { error in
            guard case .invalidObjectDigest = error as? TimeMachineObjectStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTwoTiBBandNamespaceFitsFixedShardingAndManifestObjectBounds() throws {
        let chunkSize = TimeMachineRepositorySettings.chunkSizeBytes
        let twoTiB = 2 * 1_099_511_627_776
        let bandCount = twoTiB / chunkSize
        XCTAssertEqual(bandCount, 262_144)
        XCTAssertLessThan(bandCount, TimeMachineGenerationStore.maximumRemoteFileCount)

        var indexesByPrefix: [String: [Int]] = [:]
        indexesByPrefix.reserveCapacity(4_096)
        for index in 0..<bandCount {
            let path = "Mac.sparsebundle/bands/\(String(index, radix: 16))"
            let prefix = String(
                TimeMachineGenerationStore.sha256Hex(Data(path.utf8)).prefix(3)
            )
            indexesByPrefix[prefix, default: []].append(index)
        }
        XCTAssertLessThanOrEqual(indexesByPrefix.count, 4_096)

        let digest = String(repeating: "a", count: 64)
        let storeID = UUID()
        var representedBands = 0
        var largestShardBytes = 0
        for indexes in indexesByPrefix.values {
            let files = indexes.map { index in
                TimeMachineRemoteFile(
                    path: "Mac.sparsebundle/bands/\(String(index, radix: 16))",
                    logicalSize: UInt64(chunkSize),
                    chunks: [
                        TimeMachineChunkReference(
                            index: 0,
                            objectDigest: digest,
                            byteCount: chunkSize
                        )
                    ]
                )
            }
            let shard = try TimeMachineGenerationStore.makeFileShards(
                storeID: storeID,
                files: files
            )
            XCTAssertEqual(shard.references.count, 1)
            representedBands += files.count
            largestShardBytes = max(
                largestShardBytes,
                try XCTUnwrap(shard.references.first).byteCount
            )
        }
        XCTAssertEqual(representedBands, bandCount)
        XCTAssertLessThanOrEqual(largestShardBytes, 4 * 1_048_576)
    }

    func testManifestConstructionRejectsResourceExhaustionBounds() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        XCTAssertThrowsError(
            try fixture.store.commit(
                TimeMachineGenerationCommit(
                    manifest: TimeMachineGenerationManifest(
                        storeID: fixture.storeID,
                        generation: 1,
                        parentManifestDigest: nil,
                        writerID: UUID(),
                        createdAt: fixture.now,
                        chunkSizeBytes: TimeMachineRepositorySettings.chunkSizeBytes / 2,
                        fileShards: []
                    ),
                    objectsByDigest: [String: Data]()
                )
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }
        let maximumLogicalBytes = UInt64(
            TimeMachineRepositorySettings.maximumImageCapacityBytes
                + 1_073_741_824
        )
        XCTAssertThrowsError(
            try TimeMachineGenerationStore.makeFileShards(
                storeID: fixture.storeID,
                files: [
                    TimeMachineRemoteFile(
                        path: "Mac.sparsebundle/bands/0",
                        logicalSize: maximumLogicalBytes + 1,
                        chunks: []
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }
        XCTAssertThrowsError(
            try TimeMachineGenerationStore.makeFileShards(
                storeID: fixture.storeID,
                files: [
                    TimeMachineRemoteFile(
                        path: "Mac.sparsebundle/bands/\(String(repeating: "x", count: 256))",
                        logicalSize: 0,
                        chunks: []
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }

        let excessiveDeclaredFiles = TimeMachineFileShardReference(
            prefix: "000",
            objectDigest: String(repeating: "0", count: 64),
            byteCount: 1,
            fileCount: TimeMachineGenerationStore.maximumRemoteFileCount + 1
        )
        XCTAssertThrowsError(
            try fixture.store.commit(
                TimeMachineGenerationCommit(
                    manifest: TimeMachineGenerationManifest(
                        storeID: fixture.storeID,
                        generation: 1,
                        parentManifestDigest: nil,
                        writerID: UUID(),
                        createdAt: fixture.now,
                        fileShards: [excessiveDeclaredFiles]
                    ),
                    objectsByDigest: [String: Data]()
                )
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }

        let oversizedManifestPath = "\(fixture.namespace)/manifests/00000000000000000001-\(UUID().uuidString.lowercased())-\(String(repeating: "0", count: 64)).json"
        try fixture.transport.writeObjectIfAbsent(
            Data(repeating: 0x5A, count: 4 * 1_048_576 + 1),
            at: oversizedManifestPath
        )
        XCTAssertThrowsError(try fixture.store.loadHead()) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }
    }

    func testLocalTransportRejectsPathTraversal() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(try fixture.transport.writeObjectIfAbsent(Data(), at: "../outside")) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidObjectPath("../outside"))
        }
        XCTAssertThrowsError(try fixture.transport.readObject(at: "objects/bad\0suffix")) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .invalidObjectPath("objects/bad\0suffix")
            )
        }
        let oversizedComponent = "objects/\(String(repeating: "x", count: 256))"
        XCTAssertThrowsError(
            try fixture.transport.writeObjectIfAbsent(Data(), at: oversizedComponent)
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .invalidObjectPath(oversizedComponent)
            )
        }
    }

    func testLocalTransportCreatesOnlyTheSelectedMissingRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-missing-root-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let transport = LocalTimeMachineObjectTransport(rootURL: root)

        try transport.writeObjectIfAbsent(Data("created safely".utf8), at: "one/two/value")

        XCTAssertEqual(try transport.readObject(at: "one/two/value"), Data("created safely".utf8))
    }

    func testLocalTransportDoesNotRecreateExistingDiskWhenProviderDisappears() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-provider-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = parent.appendingPathComponent("mounted-provider", isDirectory: true)
        let root = provider.appendingPathComponent("remote", isDirectory: true)
        let displaced = parent.appendingPathComponent("provider-offline", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let transport = LocalTimeMachineObjectTransport(
            rootURL: root,
            rootPolicy: .requireExisting
        )
        try transport.writeObjectIfAbsent(Data("committed".utf8), at: "objects/value")
        try FileManager.default.moveItem(at: provider, to: displaced)

        for operation in [
            { _ = try transport.listObjects(withPrefix: "") },
            { _ = try transport.readObject(at: "objects/value") },
            { try transport.writeObjectIfAbsent(Data("new".utf8), at: "objects/new") },
            { try transport.deleteObject(at: "objects/value") }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? TimeMachineObjectStoreError,
                    .localDestinationUnavailable
                )
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertEqual(
            try Data(contentsOf: displaced.appendingPathComponent("remote/objects/value")),
            Data("committed".utf8)
        )
    }

    func testTransportFactoryRequiresAnExistingLocalRootByDefault() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-factory-root-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("missing", isDirectory: true)
        let repository = BackupRepository(
            name: "Existing Disk",
            backend: .local(path: root.path),
            format: .timeMachine,
            timeMachineSettings: TimeMachineRepositorySettings(volumeName: "Existing Disk")
        )
        let transport = try TimeMachineObjectTransportFactory().make(for: repository)

        XCTAssertThrowsError(try transport.listObjects(withPrefix: "")) { error in
            XCTAssertEqual(
                error as? TimeMachineObjectStoreError,
                .localDestinationUnavailable
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLocalTransportNeverFollowsIntermediateSymlink() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-symlink-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let protected = outside.appendingPathComponent("protected", isDirectory: false)
        try Data("outside data".utf8).write(to: protected)
        try FileManager.default.createSymbolicLink(
            at: fixture.rootURL.appendingPathComponent("redirect", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try fixture.transport.writeObjectIfAbsent(Data("escaped".utf8), at: "redirect/new-object")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new-object").path))
        XCTAssertThrowsError(try fixture.transport.readObject(at: "redirect/protected"))
        XCTAssertEqual(try fixture.transport.listObjects(withPrefix: "redirect/"), [])
        XCTAssertThrowsError(try fixture.transport.deleteObject(at: "redirect/protected"))
        XCTAssertEqual(try Data(contentsOf: protected), Data("outside data".utf8))
    }

    func testLocalTransportRejectsRootSubstitutionAfterInitialization() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let displaced = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("delta-time-machine-displaced-\(UUID().uuidString)", isDirectory: true)
        let outside = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("delta-time-machine-root-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: displaced)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.moveItem(at: fixture.rootURL, to: displaced)
        try FileManager.default.createSymbolicLink(at: fixture.rootURL, withDestinationURL: outside)

        XCTAssertThrowsError(
            try fixture.transport.writeObjectIfAbsent(Data("escaped".utf8), at: "objects/value")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("objects/value").path))
    }

    func testLocalTransportRejectsHardLinkedObjectReadsAndListings() throws {
        let fixture = try ObjectStoreFixture()
        defer { fixture.cleanUp() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-hardlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let protected = outside.appendingPathComponent("protected", isDirectory: false)
        try Data("outside data".utf8).write(to: protected)
        let linked = fixture.rootURL.appendingPathComponent("linked", isDirectory: false)
        try FileManager.default.linkItem(at: protected, to: linked)

        XCTAssertThrowsError(try fixture.transport.readObject(at: "linked"))
        XCTAssertThrowsError(try fixture.transport.listObjects(withPrefix: "linked"))
        try fixture.transport.deleteObject(at: "linked")
        XCTAssertEqual(try Data(contentsOf: protected), Data("outside data".utf8))
    }
}

private struct ObjectStoreFixture {
    let rootURL: URL
    let storeID = UUID()
    let namespace: String
    let authenticationKey = Data(repeating: 0xA5, count: 32)
    let transport: LocalTimeMachineObjectTransport
    let store: TimeMachineGenerationStore
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        namespace = "delta-time-machine/v1/\(storeID.uuidString.lowercased())"
        transport = LocalTimeMachineObjectTransport(rootURL: rootURL)
        store = try TimeMachineGenerationStore(
            namespace: namespace,
            storeID: storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
    }

    func commit(
        generation: UInt64,
        parentDigest: String?,
        writerID: UUID,
        data: Data
    ) throws -> TimeMachineGenerationCommit {
        let digest = TimeMachineGenerationStore.sha256Hex(data)
        let files = [
            TimeMachineRemoteFile(
                path: "Delta.sparsebundle/bands/0",
                logicalSize: UInt64(data.count),
                chunks: [
                    TimeMachineChunkReference(index: 0, objectDigest: digest, byteCount: data.count)
                ]
            )
        ]
        let shards = try TimeMachineGenerationStore.makeFileShards(storeID: storeID, files: files)
        let manifest = TimeMachineGenerationManifest(
            storeID: storeID,
            generation: generation,
            parentManifestDigest: parentDigest,
            writerID: writerID,
            createdAt: now,
            fileShards: shards.references
        )
        var objects = shards.objectsByDigest
        objects[digest] = data
        return TimeMachineGenerationCommit(manifest: manifest, objectsByDigest: objects)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class LockedListState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFirstManifestList = true

    func consumeFirstManifestList() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isFirstManifestList else { return false }
        isFirstManifestList = false
        return true
    }
}

private final class ObjectBatchHook: @unchecked Sendable {
    private let lock = NSLock()
    var action: (@Sendable () throws -> Void)?
    private var recordedBatchByteCounts: [Int64] = []

    var batchByteCounts: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBatchByteCounts
    }

    func run(_ objects: [TimeMachineRemoteObjectWrite]) throws {
        let bytes = try objects.reduce(into: Int64(0)) { partial, object in
            let byteCount = try object.payload.byteCount()
            let (next, overflowed) = partial.addingReportingOverflow(Int64(byteCount))
            guard !overflowed else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            partial = next
        }
        lock.lock()
        recordedBatchByteCounts.append(bytes)
        let action = action
        lock.unlock()
        try action?()
    }
}

private struct HookedObjectTransport: TimeMachineRemoteObjectTransport, Sendable {
    var base: LocalTimeMachineObjectTransport
    var hook: ObjectBatchHook

    func readObject(at path: String) throws -> Data {
        try base.readObject(at: path)
    }

    func writeObjectIfAbsent(_ data: Data, at path: String) throws {
        try base.writeObjectIfAbsent(data, at: path)
    }

    func writeObjectsIfAbsent(_ objects: [TimeMachineRemoteObjectWrite]) throws {
        try base.writeObjectsIfAbsent(objects)
        try hook.run(objects)
    }

    func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata] {
        try base.listObjects(withPrefix: prefix)
    }

    func deleteObject(at path: String) throws {
        try base.deleteObject(at: path)
    }
}
