import CryptoKit
import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineSparseFileSessionTests: XCTestCase {
    func testCacheDirectoriesArePrivateAndRejectSubstitutedRootSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-private-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        _ = try TimeMachineSparseFileSession(
            cacheURL: cache,
            storeID: UUID(),
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: 16
        )
        for directory in [
            cache,
            cache.appendingPathComponent("clean", isDirectory: true),
            cache.appendingPathComponent("dirty", isDirectory: true)
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }

        let target = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let substituted = root.appendingPathComponent("substituted-cache", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: substituted, withDestinationURL: target)
        XCTAssertThrowsError(
            try TimeMachineSparseFileSession(
                cacheURL: substituted,
                storeID: UUID(),
                writerID: UUID(),
                cacheLimitBytes: 1_048_576,
                chunkSize: 16
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCacheAccountingFailsClosedForSubstitutedEntry() throws {
        let fixture = try SparseSessionFixture(
            chunkSize: 16,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let outside = fixture.rootURL.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        let substituted = fixture.cacheURL
            .appendingPathComponent("clean", isDirectory: true)
            .appendingPathComponent("forged")
        try FileManager.default.createSymbolicLink(
            at: substituted,
            withDestinationURL: outside
        )

        XCTAssertEqual(
            fixture.session.cacheUsage().totalBytes,
            fixture.session.cacheUsage().limitBytes
        )
        XCTAssertThrowsError(
            try fixture.session.write(
                path: "Mac.sparsebundle/bands/0",
                offset: 0,
                data: Data("blocked".utf8)
            ) { try fixture.store.readChunk($0) }
        )
        XCTAssertNil(fixture.session.logicalSize(of: "Mac.sparsebundle/bands/0"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testDirtyCacheReadNeverFollowsSubstitutedEntry() throws {
        let fixture = try SparseSessionFixture(
            chunkSize: 16,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        try fixture.session.write(
            path: path,
            offset: 0,
            data: Data("original".utf8)
        ) { try fixture.store.readChunk($0) }
        let dirtyDirectory = fixture.cacheURL.appendingPathComponent("dirty", isDirectory: true)
        let dirtyURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: dirtyDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let outside = fixture.rootURL.appendingPathComponent("outside-secret")
        try Data("must not be read".utf8).write(to: outside)
        try FileManager.default.removeItem(at: dirtyURL)
        try FileManager.default.createSymbolicLink(
            at: dirtyURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try fixture.session.read(path: path, offset: 0, length: 8) {
                try fixture.store.readChunk($0)
            }
        )
        XCTAssertThrowsError(try fixture.session.prepareCommit(createdAt: fixture.now))
        XCTAssertEqual(try Data(contentsOf: outside), Data("must not be read".utf8))
    }

    func testPartialWritesCommitAndReadAfterFreshSession() throws {
        let chunkSize = TimeMachineRepositorySettings.chunkSizeBytes
        let cacheLimitBytes = Int64(chunkSize * 3)
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: cacheLimitBytes
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        let first = Data((0..<20).map(UInt8.init))

        let writeOffset = UInt64(chunkSize - 5)
        try fixture.session.write(path: path, offset: writeOffset, data: first) { try fixture.store.readChunk($0) }
        let prepared = try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        let committed = try fixture.store.commit(prepared)
        try fixture.session.acceptCommittedHead(committed)
        let remoteFiles = try fixture.store.loadFiles(from: committed)

        let fresh = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: cacheLimitBytes,
            chunkSize: chunkSize,
            head: committed,
            remoteFiles: remoteFiles
        )
        let restored = try fresh.read(path: path, offset: writeOffset - 5, length: 25) { try fixture.store.readChunk($0) }

        XCTAssertEqual(restored.prefix(5), Data(repeating: 0, count: 5))
        XCTAssertEqual(restored.dropFirst(5), first)
        XCTAssertEqual(fresh.logicalSize(of: path), UInt64(chunkSize + 15))
    }

    func testTwoAuthenticatedHotChunksServeRepeatedSmallDiskImagesReads() throws {
        let chunkSize = 16
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let paths = ["Mac.sparsebundle/bands/0", "Mac.sparsebundle/bands/1"]
        let bands = [
            Data((0..<chunkSize).map(UInt8.init)),
            Data((chunkSize..<(chunkSize * 2)).map(UInt8.init))
        ]
        for (path, band) in zip(paths, bands) {
            try fixture.session.write(path: path, offset: 0, data: band) {
                try fixture.store.readChunk($0)
            }
        }
        let committed = try fixture.store.commit(
            try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        )
        try fixture.session.acceptCommittedHead(committed)
        let fresh = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: chunkSize,
            head: committed,
            remoteFiles: try fixture.store.loadFiles(from: committed)
        )

        for (path, band) in zip(paths, bands) {
            XCTAssertEqual(
                try fresh.read(path: path, offset: 0, length: 1) {
                    try fixture.store.readChunk($0)
                },
                band.subdata(in: 0..<1)
            )
        }
        let cleanDirectory = fixture.freshCacheURL.appendingPathComponent(
            "clean",
            isDirectory: true
        )
        for url in try FileManager.default.contentsOfDirectory(
            at: cleanDirectory,
            includingPropertiesForKeys: nil
        ) {
            try Data("changed after authentication".utf8).write(to: url)
        }

        for (path, band) in zip(paths, bands) {
            XCTAssertEqual(
                try fresh.read(path: path, offset: 0, length: 1) { _ in
                    throw POSIXError(.ENETDOWN)
                },
                band.subdata(in: 0..<1)
            )
        }
    }

    func testThirdAuthenticatedChunkReusesTheEvictedHotBuffer() throws {
        let chunkSize = 4_096
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let paths = (0..<3).map { "Mac.sparsebundle/bands/\($0)" }
        for (index, path) in paths.enumerated() {
            try fixture.session.write(
                path: path,
                offset: 0,
                data: Data(repeating: UInt8(index + 1), count: chunkSize)
            ) { try fixture.store.readChunk($0) }
        }
        let committed = try fixture.store.commit(
            try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        )
        try fixture.session.acceptCommittedHead(committed)
        let fresh = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: chunkSize,
            head: committed,
            remoteFiles: try fixture.store.loadFiles(from: committed)
        )
        let recorder = ReusedBufferRecorder()

        for (index, path) in paths.enumerated() {
            XCTAssertEqual(
                try fresh.read(
                    path: path,
                    offset: 0,
                    length: 1,
                    reusingRemoteLoader: { reference, buffer in
                        let incomingCount = buffer.count
                        let incomingAddress = buffer.withUnsafeBytes {
                            UInt(bitPattern: $0.baseAddress)
                        }
                        try fixture.store.readChunk(reference, into: &buffer)
                        recorder.record(
                            count: incomingCount,
                            incomingAddress: incomingAddress,
                            loadedAddress: buffer.withUnsafeBytes {
                                UInt(bitPattern: $0.baseAddress)
                            }
                        )
                    }
                ),
                Data([UInt8(index + 1)])
            )
        }

        XCTAssertEqual(recorder.values.map(\.count), [0, 0, chunkSize])
        XCTAssertEqual(
            recorder.values[2].incomingAddress,
            recorder.values[2].loadedAddress,
            "The third remote read must overwrite the uniquely evicted band allocation in place."
        )
    }

    func testIdenticalAuthenticatedBandRewriteCommitsWithoutRedundantPayload() throws {
        let chunkSize = 16
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/19"
        let band = Data((0..<chunkSize).map(UInt8.init))

        try fixture.session.write(path: path, offset: 0, data: band) {
            try fixture.store.readChunk($0)
        }
        let firstCommit = try XCTUnwrap(
            fixture.session.prepareCommit(createdAt: fixture.now)
        )
        let firstHead = try fixture.store.commit(firstCommit)
        try fixture.session.acceptCommittedHead(firstHead)

        try fixture.session.write(path: path, offset: 0, data: band) {
            try fixture.store.readChunk($0)
        }
        XCTAssertGreaterThan(fixture.session.cacheUsage().dirtyBytes, 0)
        XCTAssertLessThanOrEqual(
            fixture.session.cacheUsage().totalBytes,
            fixture.session.cacheUsage().limitBytes
        )

        let repeatedCommit = try XCTUnwrap(
            fixture.session.prepareCommit(createdAt: fixture.now.addingTimeInterval(1))
        )
        XCTAssertEqual(
            repeatedCommit.manifest.fileShards,
            firstHead.signedManifest.manifest.fileShards
        )
        XCTAssertTrue(
            repeatedCommit.objectsByDigest.isEmpty,
            "An identical rewrite is already authenticated remotely and must not be supplied as a changed object."
        )

        let repeatedHead = try fixture.store.commit(repeatedCommit)
        XCTAssertEqual(repeatedHead.signedManifest.manifest.generation, 2)
        try fixture.session.acceptCommittedHead(repeatedHead)
        XCTAssertEqual(fixture.session.cacheUsage().dirtyBytes, 0)
        XCTAssertEqual(
            try fixture.session.read(path: path, offset: 0, length: band.count) {
                try fixture.store.readChunk($0)
            },
            band
        )
    }

    func testDirtyDataIsNeverEvictedWhenCacheIsFull() throws {
        let chunkSize = TimeMachineRepositorySettings.chunkSizeBytes
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: Int64(chunkSize)
        )
        defer { fixture.cleanUp() }
        let data = Data(repeating: 0xA5, count: chunkSize)

        try fixture.session.write(path: "Mac.sparsebundle/bands/0", offset: 0, data: data) { try fixture.store.readChunk($0) }
        XCTAssertThrowsError(
            try fixture.session.write(path: "Mac.sparsebundle/bands/1", offset: 0, data: data) { try fixture.store.readChunk($0) }
        ) { error in
            guard case .cacheLimitExceeded = error as? TimeMachineSparseFileSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let usage = fixture.session.cacheUsage()
        XCTAssertEqual(usage.dirtyBytes, Int64(chunkSize))
        XCTAssertLessThanOrEqual(usage.totalBytes, usage.limitBytes)
        XCTAssertNotNil(try fixture.session.prepareCommit(createdAt: fixture.now))
    }

    func testDirtyCacheSpillFreesLocalWindowWithoutPublishingGeneration() throws {
        let chunkSize = 16
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: Int64(chunkSize)
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        let data = Data((0..<chunkSize).map(UInt8.init))
        try fixture.session.write(path: path, offset: 0, data: data) {
            try fixture.store.readChunk($0)
        }
        let spill = try XCTUnwrap(fixture.session.prepareDirtyCacheSpill())
        let lease = try fixture.store.acquireLease(
            ownerID: UUID(),
            duration: 300,
            now: fixture.now
        )

        try fixture.store.stageObjects(
            spill.objectsByDigest,
            lease: lease,
            now: fixture.now
        )
        XCTAssertNil(try fixture.store.loadHead())
        XCTAssertEqual(try fixture.session.acceptDirtyCacheSpill(spill), 1)
        XCTAssertEqual(fixture.session.cacheUsage().dirtyBytes, 0)
        XCTAssertEqual(
            try fixture.session.read(path: path, offset: 0, length: data.count) {
                try fixture.store.readChunk($0)
            },
            data
        )

        let restartedBeforePublication = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: Int64(chunkSize),
            chunkSize: chunkSize
        )
        XCTAssertEqual(
            try restartedBeforePublication.read(
                path: path,
                offset: 0,
                length: data.count
            ) { try fixture.store.readChunk($0) },
            Data(),
            "A service restart before sync must restore the authenticated head, not staged bytes."
        )
        XCTAssertNil(try fixture.store.loadHead())

        try fixture.store.releaseLease(lease)
        let prepared = try XCTUnwrap(
            fixture.session.prepareCommit(createdAt: fixture.now)
        )
        let payloadDigest = TimeMachineGenerationStore.sha256Hex(data)
        XCTAssertNil(
            prepared.objectsByDigest[payloadDigest],
            "The staged band must be referenced remotely instead of retained locally."
        )
        let committed = try fixture.store.commit(prepared)
        try fixture.session.acceptCommittedHead(committed)
        XCTAssertEqual(committed.signedManifest.manifest.generation, 1)
        XCTAssertEqual(
            try fixture.store.readChunk(
                try XCTUnwrap(fixture.store.loadFiles(from: committed).first?.chunks.first)
            ),
            data
        )
    }

    func testDirtyCacheSpillBatchIsIndependentOfConfiguredCacheSize() throws {
        let chunkSize = 16
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        for index in 0..<20 {
            try fixture.session.write(
                path: "Mac.sparsebundle/bands/\(index)",
                offset: 0,
                data: Data([UInt8(index)])
            ) { try fixture.store.readChunk($0) }
        }
        let spill = try XCTUnwrap(
            fixture.session.prepareDirtyCacheSpill(maximumBytes: 4 * Int64(chunkSize))
        )
        XCTAssertEqual(spill.entries.count, 4)
        let dirtyBytesBeforeSpill = fixture.session.cacheUsage().dirtyBytes

        let lease = try fixture.store.acquireLease(
            ownerID: UUID(),
            duration: 300,
            now: fixture.now
        )
        try fixture.store.stageObjects(
            spill.objectsByDigest,
            lease: lease,
            now: fixture.now
        )
        XCTAssertEqual(try fixture.session.acceptDirtyCacheSpill(spill), 4)
        XCTAssertLessThan(
            fixture.session.cacheUsage().dirtyBytes,
            dirtyBytesBeforeSpill
        )
        XCTAssertNil(try fixture.store.loadHead())
    }

    func testUsedDataCountsEveryReferencedExtentEvenWhenContentIsDeduplicated() throws {
        let fixture = try SparseSessionFixture(
            chunkSize: 16,
            cacheLimitBytes: 1_048_576
        )
        defer { fixture.cleanUp() }
        let repeated = Data(repeating: 0xA7, count: 16)
        for path in [
            "Mac.sparsebundle/bands/0",
            "Mac.sparsebundle/bands/1"
        ] {
            try fixture.session.write(path: path, offset: 0, data: repeated) {
                try fixture.store.readChunk($0)
            }
        }
        let head = try fixture.store.commit(
            try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        )
        try fixture.session.acceptCommittedHead(head)

        XCTAssertEqual(fixture.session.usedDataBytes(), 32)
    }

    func testMultiChunkWriteThatExceedsCacheDoesNotPartiallyMutateSession() throws {
        let chunkSize = TimeMachineRepositorySettings.chunkSizeBytes
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: Int64(chunkSize)
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/atomic"

        XCTAssertThrowsError(
            try fixture.session.write(
                path: path,
                offset: 0,
                data: Data(repeating: 0xC3, count: chunkSize * 2)
            ) { try fixture.store.readChunk($0) }
        ) { error in
            guard case .cacheLimitExceeded = error as? TimeMachineSparseFileSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(fixture.session.logicalSize(of: path))
        XCTAssertEqual(fixture.session.cacheUsage().dirtyBytes, 0)
        XCTAssertNil(try fixture.session.prepareCommit(createdAt: fixture.now))
    }

    func testFailedTruncateUnderCachePressurePreservesCommittedFile() throws {
        let chunkSize = TimeMachineRepositorySettings.chunkSizeBytes
        let fixture = try SparseSessionFixture(
            chunkSize: chunkSize,
            cacheLimitBytes: Int64(chunkSize * 4)
        )
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/target"
        let original = Data(repeating: 0x6A, count: chunkSize * 2)
        try fixture.session.write(path: path, offset: 0, data: original) {
            try fixture.store.readChunk($0)
        }
        let commit = try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        let head = try fixture.store.commit(commit)
        try fixture.session.acceptCommittedHead(head)
        let pressured = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: Int64(chunkSize),
            chunkSize: chunkSize,
            head: head,
            remoteFiles: try fixture.store.loadFiles(from: head)
        )
        try pressured.write(
            path: "Mac.sparsebundle/bands/other",
            offset: 0,
            data: Data(repeating: 0xB4, count: chunkSize)
        ) { try fixture.store.readChunk($0) }

        XCTAssertThrowsError(
            try pressured.truncate(path: path, size: UInt64(chunkSize + 100)) {
                try fixture.store.readChunk($0)
            }
        ) { error in
            guard case .cacheLimitExceeded = error as? TimeMachineSparseFileSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(pressured.logicalSize(of: path), UInt64(original.count))
        XCTAssertEqual(
            try pressured.read(path: path, offset: UInt64(chunkSize), length: 16) {
                try fixture.store.readChunk($0)
            },
            Data(repeating: 0x6A, count: 16)
        )
        XCTAssertLessThanOrEqual(
            pressured.cacheUsage().totalBytes,
            pressured.cacheUsage().limitBytes
        )
    }

    func testRenameOverExistingFileCommitsSourceContentAtDestination() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let source = "Mac.sparsebundle/source"
        let destination = "Mac.sparsebundle/destination"
        try fixture.session.write(path: source, offset: 0, data: Data("source".utf8)) {
            try fixture.store.readChunk($0)
        }
        try fixture.session.write(path: destination, offset: 0, data: Data("old".utf8)) {
            try fixture.store.readChunk($0)
        }

        try fixture.session.rename(path: source, to: destination)
        let head = try fixture.store.commit(
            try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        )
        try fixture.session.acceptCommittedHead(head)
        let restarted = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: 16,
            head: head,
            remoteFiles: try fixture.store.loadFiles(from: head)
        )

        XCTAssertNil(restarted.logicalSize(of: source))
        XCTAssertEqual(
            try restarted.read(path: destination, offset: 0, length: 6) {
                try fixture.store.readChunk($0)
            },
            Data("source".utf8)
        )
    }

    func testSparsebundleDirectoryPromotionRebasesEveryRemoteFileAndSurvivesRestart() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let staging = "store.creating.sparsebundle"
        let final = "store.sparsebundle"
        let infoPath = "\(staging)/Info.plist"
        let bandPath = "\(staging)/bands/0"
        let info = Data("plist".utf8)
        let band = Data("band-payload".utf8)

        try fixture.session.write(path: infoPath, offset: 0, data: info) {
            try fixture.store.readChunk($0)
        }
        try fixture.session.write(path: bandPath, offset: 0, data: band) {
            try fixture.store.readChunk($0)
        }

        try fixture.session.rename(path: staging, to: final)
        XCTAssertNil(fixture.session.logicalSize(of: infoPath))
        XCTAssertNil(fixture.session.logicalSize(of: bandPath))
        XCTAssertEqual(fixture.session.logicalSize(of: "\(final)/Info.plist"), UInt64(info.count))
        XCTAssertEqual(fixture.session.logicalSize(of: "\(final)/bands/0"), UInt64(band.count))

        let head = try fixture.store.commit(
            try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        )
        try fixture.session.acceptCommittedHead(head)
        let restarted = try TimeMachineSparseFileSession(
            cacheURL: fixture.freshCacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: 16,
            head: head,
            remoteFiles: try fixture.store.loadFiles(from: head)
        )

        XCTAssertNil(restarted.logicalSize(of: infoPath))
        XCTAssertNil(restarted.logicalSize(of: bandPath))
        XCTAssertEqual(
            try restarted.read(path: "\(final)/Info.plist", offset: 0, length: info.count) {
                try fixture.store.readChunk($0)
            },
            info
        )
        XCTAssertEqual(
            try restarted.read(path: "\(final)/bands/0", offset: 0, length: band.count) {
                try fixture.store.readChunk($0)
            },
            band
        )
    }

    func testDirectoryRenameRefusesUnrelatedDestinationContentWithoutMutation() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let sourcePath = "source.sparsebundle/bands/0"
        let destinationPath = "destination.sparsebundle/bands/existing"
        try fixture.session.create(path: sourcePath)
        try fixture.session.create(path: destinationPath)

        XCTAssertThrowsError(
            try fixture.session.rename(
                path: "source.sparsebundle",
                to: "destination.sparsebundle"
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineSparseFileSessionError,
                .renameDestinationNotEmpty
            )
        }
        XCTAssertEqual(fixture.session.logicalSize(of: sourcePath), 0)
        XCTAssertEqual(fixture.session.logicalSize(of: destinationPath), 0)
        XCTAssertNil(fixture.session.logicalSize(of: "destination.sparsebundle/bands/0"))
    }

    func testDirectoryRenameRejectsMovingInsideItselfWithoutMutation() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let path = "store.sparsebundle/bands/0"
        try fixture.session.write(
            path: path,
            offset: 0,
            data: Data("preserved".utf8)
        ) { try fixture.store.readChunk($0) }

        XCTAssertThrowsError(
            try fixture.session.rename(
                path: "store.sparsebundle",
                to: "store.sparsebundle/nested"
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineSparseFileSessionError,
                .invalidRename
            )
        }
        XCTAssertEqual(
            try fixture.session.read(path: path, offset: 0, length: 9) {
                try fixture.store.readChunk($0)
            },
            Data("preserved".utf8)
        )
    }

    func testRenameNeverFollowsSubstitutedDirtyDestination() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let source = "Mac.sparsebundle/source"
        let destination = "Mac.sparsebundle/destination"
        try fixture.session.write(
            path: source,
            offset: 0,
            data: Data("source".utf8)
        ) { try fixture.store.readChunk($0) }
        try fixture.session.write(
            path: destination,
            offset: 0,
            data: Data("destination".utf8)
        ) { try fixture.store.readChunk($0) }

        let keyData = Data("\(destination)\u{0}0".utf8)
        let dirtyName = SHA256.hash(data: keyData)
            .map { String(format: "%02x", $0) }
            .joined()
        let dirtyURL = fixture.cacheURL
            .appendingPathComponent("dirty", isDirectory: true)
            .appendingPathComponent(dirtyName)
        let outside = fixture.rootURL.appendingPathComponent("outside-secret")
        let outsideData = Data("must not be read".utf8)
        try outsideData.write(to: outside)
        try FileManager.default.removeItem(at: dirtyURL)
        try FileManager.default.createSymbolicLink(
            at: dirtyURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try fixture.session.rename(path: source, to: destination)
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        XCTAssertEqual(fixture.session.logicalSize(of: source), 6)
        XCTAssertEqual(fixture.session.logicalSize(of: destination), 11)
    }

    func testFailedRemotePublicationKeepsDirtyGenerationForRetry() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        try fixture.session.write(path: path, offset: 0, data: Data("pending".utf8)) { try fixture.store.readChunk($0) }
        let commit = try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now))
        let failing = AnyTimeMachineRemoteObjectTransport(
            read: fixture.transport.readObject,
            writeIfAbsent: { data, remotePath in
                if remotePath.contains("/manifests/") {
                    throw POSIXError(.ENETDOWN)
                }
                try fixture.transport.writeObjectIfAbsent(data, at: remotePath)
            },
            list: fixture.transport.listObjects,
            delete: fixture.transport.deleteObject
        )
        let failingStore = try TimeMachineGenerationStore(
            namespace: fixture.namespace,
            storeID: fixture.storeID,
            authenticationKey: fixture.authenticationKey,
            transport: failing
        )

        XCTAssertThrowsError(try failingStore.commit(commit))
        XCTAssertNil(try fixture.store.loadHead())
        XCTAssertGreaterThan(fixture.session.cacheUsage().dirtyBytes, 0)

        let retried = try fixture.store.commit(try XCTUnwrap(fixture.session.prepareCommit(createdAt: fixture.now)))
        try fixture.session.acceptCommittedHead(retried)
        XCTAssertEqual(fixture.session.cacheUsage().dirtyBytes, 0)
        XCTAssertEqual(
            try fixture.session.read(path: path, offset: 0, length: 7) { try fixture.store.readChunk($0) },
            Data("pending".utf8)
        )
    }

    func testCommittedRemoteGenerationDoesNotBecomeRetryableWhenCachePromotionFails() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        let data = Data("durable".utf8)
        try fixture.session.write(path: path, offset: 0, data: data) {
            try fixture.store.readChunk($0)
        }
        let commit = try XCTUnwrap(
            fixture.session.prepareCommit(createdAt: fixture.now)
        )
        let committed = try fixture.store.commit(commit)
        let cleanDirectory = fixture.cacheURL.appendingPathComponent(
            "clean",
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: cleanDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cleanDirectory.path
            )
        }

        XCTAssertEqual(
            try fixture.session.acceptCommittedHead(committed),
            .cacheCleanupDeferred
        )
        XCTAssertNil(try fixture.session.prepareCommit(createdAt: fixture.now))
        XCTAssertEqual(
            try fixture.session.read(path: path, offset: 0, length: data.count) {
                try fixture.store.readChunk($0)
            },
            data
        )
        XCTAssertEqual(
            fixture.session.takeCacheMaintenanceWarning(),
            "Delta could not update its reconstructible Time Machine read cache. Verified remote data remains available."
        )
        XCTAssertNil(fixture.session.takeCacheMaintenanceWarning())
    }

    func testFreshSessionDiscardsUncommittedLocalDirtyState() throws {
        let fixture = try SparseSessionFixture(chunkSize: 16, cacheLimitBytes: 1_048_576)
        defer { fixture.cleanUp() }
        let path = "Mac.sparsebundle/bands/0"
        try fixture.session.write(path: path, offset: 0, data: Data("volatile".utf8)) { try fixture.store.readChunk($0) }
        XCTAssertGreaterThan(fixture.session.cacheUsage().dirtyBytes, 0)

        let restarted = try TimeMachineSparseFileSession(
            cacheURL: fixture.cacheURL,
            storeID: fixture.storeID,
            writerID: UUID(),
            cacheLimitBytes: 1_048_576,
            chunkSize: 16,
            head: nil
        )

        XCTAssertNil(restarted.logicalSize(of: path))
        XCTAssertEqual(restarted.cacheUsage().dirtyBytes, 0)
        XCTAssertEqual(try restarted.read(path: path, offset: 0, length: 8) { try fixture.store.readChunk($0) }, Data())
    }
}

private final class ReusedBufferRecorder: @unchecked Sendable {
    struct Value {
        var count: Int
        var incomingAddress: UInt
        var loadedAddress: UInt
    }

    private let lock = NSLock()
    private var recordedValues: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(count: Int, incomingAddress: UInt, loadedAddress: UInt) {
        lock.lock()
        recordedValues.append(
            Value(
                count: count,
                incomingAddress: incomingAddress,
                loadedAddress: loadedAddress
            )
        )
        lock.unlock()
    }
}

private struct SparseSessionFixture {
    let rootURL: URL
    let cacheURL: URL
    let freshCacheURL: URL
    let storeID = UUID()
    let namespace: String
    let authenticationKey = Data(repeating: 0x5A, count: 32)
    let transport: LocalTimeMachineObjectTransport
    let store: TimeMachineGenerationStore
    let session: TimeMachineSparseFileSession
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init(chunkSize: Int, cacheLimitBytes: Int64) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-session-\(UUID().uuidString)", isDirectory: true)
        cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        freshCacheURL = rootURL.appendingPathComponent("fresh-cache", isDirectory: true)
        let remoteURL = rootURL.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        namespace = "delta-time-machine/v1/\(storeID.uuidString.lowercased())"
        transport = LocalTimeMachineObjectTransport(rootURL: remoteURL)
        store = try TimeMachineGenerationStore(
            namespace: namespace,
            storeID: storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        session = try TimeMachineSparseFileSession(
            cacheURL: cacheURL,
            storeID: storeID,
            writerID: UUID(),
            cacheLimitBytes: cacheLimitBytes,
            chunkSize: chunkSize
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
