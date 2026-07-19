import Darwin
import DeltaTimeMachineIPC
import Foundation
import XCTest
@testable import DeltaCore

final class TimeMachineRuntimePathsTests: XCTestCase {
    func testControlSocketUsesSupportedAppGroupContainerAndCompactRepositoryName() throws {
        let repositoryID = UUID(uuidString: "39E7D60D-07B8-4123-A9DE-85F2275D6DC1")!
        let group = URL(
            fileURLWithPath: "/Users/test/Library/Group Containers/BJCVJ5G7MJ.deltatm",
            isDirectory: true
        )
        let socket = try TimeMachineRuntimePaths.socketURL(
            repositoryID: repositoryID,
            applicationGroupContainerURL: group
        )
        let address = sockaddr_un()

        XCTAssertEqual(
            socket.deletingLastPathComponent(),
            group.appendingPathComponent(".i", isDirectory: true)
        )
        XCTAssertEqual(socket.lastPathComponent, "dOefWDQe4QSOp3g")
        XCTAssertLessThan(
            socket.path.utf8.count,
            MemoryLayout.size(ofValue: address.sun_path)
        )
    }

    func testControlSocketNamesAreStableAndRepositoryScoped() throws {
        let group = URL(fileURLWithPath: "/tmp/delta-time-machine-ipc-tests", isDirectory: true)
        let firstID = UUID(uuidString: "39E7D60D-07B8-4123-A9DE-85F2275D6DC1")!
        let secondID = UUID(uuidString: "49E7D60D-07B8-4123-A9DE-85F2275D6DC1")!

        let first = try TimeMachineRuntimePaths.socketURL(
            repositoryID: firstID,
            applicationGroupContainerURL: group
        )
        XCTAssertEqual(
            first,
            try TimeMachineRuntimePaths.socketURL(
                repositoryID: firstID,
                applicationGroupContainerURL: group
            )
        )
        XCTAssertNotEqual(
            first,
            try TimeMachineRuntimePaths.socketURL(
                repositoryID: secondID,
                applicationGroupContainerURL: group
            )
        )
    }

    func testDiskProtocolBindsAndReconnectsInsideAppGroupFixture() throws {
        let repositoryID = UUID()
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-socket-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let ipcContainer = URL(
            fileURLWithPath: "/tmp/dtm-ipc-\(repositoryID.uuidString.prefix(8))",
            isDirectory: true
        )
        let socket = try TimeMachineRuntimePaths.socketURL(
            repositoryID: repositoryID,
            applicationGroupContainerURL: ipcContainer
        )
        let server = TimeMachineDiskProtocolServer(
            socketPath: socket.path,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(
                    repositoryID: repositoryID,
                    capacityBytes: 1_099_511_627_776
                )
            )
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: ipcContainer)
        }

        try server.start()
        try server.start()
        let result = try TimeMachineDiskProtocolClient(
            socketPath: socket.path,
            repositoryID: repositoryID,
            peerValidator: { $0.count == 32 }
        ).perform(
            TimeMachineDiskRequest(operation: .status)
        )
        XCTAssertEqual(result.response.capacityBytes, 1_099_511_627_776)

        server.stop()
        server.stop()
        XCTAssertFalse(lstatExists(socket.path))
    }

    func testSourceValidationRequiresExactPrivateRepositoryMarkerAndRejectsSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-source-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let repositoryID = UUID()
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )

        XCTAssertNoThrow(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid()
            )
        )
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: UUID(),
                expectedOwnerID: geteuid()
            )
        )

        let link = root.appendingPathComponent("source-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                link,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid()
            )
        )
    }

    func testSourceDiskImageCheckBindsRepositoryAndMountSessionOnOnePrivateRoot() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-source-image-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let repositoryID = UUID()
        let mountSessionID = UUID()
        let settings = TimeMachineRepositorySettings(
            storeID: UUID(),
            volumeName: "History"
        )
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )
        try TimeMachineRuntimePaths.prepareMountSession(
            repositoryID: repositoryID,
            mountSessionID: mountSessionID,
            applicationSupportURL: support
        )

        XCTAssertFalse(
            try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: source,
                repositoryID: repositoryID,
                expectedMountSessionID: mountSessionID,
                settings: settings,
                expectedOwnerID: geteuid()
            )
        )

        let image = source.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: image,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: image.path
        )

        XCTAssertTrue(
            try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: source,
                repositoryID: repositoryID,
                expectedMountSessionID: mountSessionID,
                settings: settings,
                expectedOwnerID: geteuid()
            )
        )
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: source,
                repositoryID: repositoryID,
                expectedMountSessionID: UUID(),
                settings: settings,
                expectedOwnerID: geteuid()
            )
        )
    }

    func testSourceDiskImageCheckRejectsSymlinkAndUnsafePermissions() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-source-image-substitution-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let repositoryID = UUID()
        let mountSessionID = UUID()
        let settings = TimeMachineRepositorySettings(
            storeID: UUID(),
            volumeName: "History"
        )
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )
        try TimeMachineRuntimePaths.prepareMountSession(
            repositoryID: repositoryID,
            mountSessionID: mountSessionID,
            applicationSupportURL: support
        )
        let image = source.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            isDirectory: true
        )
        let outside = support.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: outside)

        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: source,
                repositoryID: repositoryID,
                expectedMountSessionID: mountSessionID,
                settings: settings,
                expectedOwnerID: geteuid()
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        try FileManager.default.removeItem(at: image)
        try FileManager.default.createDirectory(
            at: image,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: image.path
        )
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: source,
                repositoryID: repositoryID,
                expectedMountSessionID: mountSessionID,
                settings: settings,
                expectedOwnerID: geteuid()
            )
        )
    }

    func testMountedOwnershipPolicyAcceptsProjectionOnlyWhenMountDeclaresIt() {
        XCTAssertTrue(
            TimeMachineMountedOwnershipPolicy.accepts(
                observedOwnerID: 503,
                expectedOwnerID: 503,
                mountIgnoresOwnership: false
            )
        )
        XCTAssertFalse(
            TimeMachineMountedOwnershipPolicy.accepts(
                observedOwnerID: 0,
                expectedOwnerID: 503,
                mountIgnoresOwnership: false
            )
        )
        XCTAssertTrue(
            TimeMachineMountedOwnershipPolicy.accepts(
                observedOwnerID: 0,
                expectedOwnerID: 503,
                mountIgnoresOwnership: true
            )
        )
    }

    func testMountSessionMarkerQualifiesOneConnectionAndSurvivesBackendReload() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-session-marker-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let repositoryID = UUID()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )

        try TimeMachineRuntimePaths.prepareMountSession(
            repositoryID: repositoryID,
            mountSessionID: firstSessionID,
            applicationSupportURL: support
        )
        XCTAssertNoThrow(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid(),
                expectedMountSessionID: firstSessionID
            )
        )
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid(),
                expectedMountSessionID: secondSessionID
            )
        )

        // Re-materializing a backend must not delete the live FSKit session
        // identity needed for root-descriptor recovery after service restart.
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )
        XCTAssertEqual(
            try String(
                contentsOf: source.appendingPathComponent(
                    TimeMachineRuntimePaths.mountSessionMarkerFileName
                ),
                encoding: .utf8
            ),
            firstSessionID.uuidString
        )

        try TimeMachineRuntimePaths.prepareMountSession(
            repositoryID: repositoryID,
            mountSessionID: secondSessionID,
            applicationSupportURL: support
        )
        XCTAssertNoThrow(
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid(),
                expectedMountSessionID: secondSessionID
            )
        )
    }

    func testMountSessionMarkerReplacesSymlinkWithoutFollowingIt() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-session-marker-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let repositoryID = UUID()
        let sessionID = UUID()
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )
        let outside = support.appendingPathComponent("outside")
        let protectedData = Data("retain".utf8)
        try protectedData.write(to: outside)
        let marker = source.appendingPathComponent(
            TimeMachineRuntimePaths.mountSessionMarkerFileName
        )
        try FileManager.default.createSymbolicLink(
            at: marker,
            withDestinationURL: outside
        )

        try TimeMachineRuntimePaths.prepareMountSession(
            repositoryID: repositoryID,
            mountSessionID: sessionID,
            applicationSupportURL: support
        )

        XCTAssertEqual(try Data(contentsOf: outside), protectedData)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), sessionID.uuidString)
        var markerStatus = stat()
        XCTAssertEqual(Darwin.lstat(marker.path, &markerStatus), 0)
        XCTAssertEqual(markerStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(markerStatus.st_nlink, 1)
    }

    func testImageCreationStagingPathStreamsRemotelyAndIsDistinctFromFinalImage() {
        let storeID = UUID(uuidString: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A")!
        let settings = TimeMachineRepositorySettings(
            storeID: storeID,
            volumeName: "History"
        )

        XCTAssertEqual(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            "6a02f7b3-e3d0-4b84-89a1-c2e9127f9b5a.sparsebundle"
        )
        let stagingName = TimeMachineRuntimePaths.diskImageStagingName(settings: settings)
        XCTAssertEqual(
            stagingName,
            "6a02f7b3-e3d0-4b84-89a1-c2e9127f9b5a.creating.sparsebundle"
        )
        XCTAssertFalse(stagingName.hasPrefix(".delta-"))
        XCTAssertNotEqual(
            stagingName,
            TimeMachineRuntimePaths.diskImageName(settings: settings)
        )
        XCTAssertEqual(
            TimeMachineRepositorySettings.sparsebundleFileSystemName,
            "Case-sensitive APFS"
        )
    }

    func testPlaceholderRecoveryRemovesInterruptedPromotionAndRebuildsCommittedNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-placeholder-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let staleFinal = source.appendingPathComponent(
            "store.sparsebundle/bands/0",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: staleFinal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleFinal)
        let outside = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let unexpectedLink = source.appendingPathComponent("unexpected-link")
        try FileManager.default.createSymbolicLink(at: unexpectedLink, withDestinationURL: outside)
        let committedPath = "store.creating.sparsebundle/bands/0"

        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [
                TimeMachineRemoteFile(
                    path: committedPath,
                    logicalSize: 8 * 1_048_576,
                    chunks: []
                )
            ],
            sourceDirectory: source,
            repositoryID: UUID(uuidString: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A")!
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("store.sparsebundle").path
            )
        )
        XCTAssertFalse(lstatExists(unexpectedLink.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        let committed = source.appendingPathComponent(committedPath)
        XCTAssertEqual(
            try committed.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            8 * 1_048_576
        )
        XCTAssertEqual(
            try String(
                contentsOf: source.appendingPathComponent(".delta-repository-id"),
                encoding: .utf8
            ),
            "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"
        )
        let sourceMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(sourceMode.intValue & 0o777, 0o700)
    }

    func testPlaceholderRecoveryReplacesHardLinkWithoutTruncatingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-placeholder-hardlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let expected = source.appendingPathComponent("store.sparsebundle/bands/0")
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outside = root.appendingPathComponent("outside")
        let protectedData = Data("must remain untouched".utf8)
        try protectedData.write(to: outside)
        XCTAssertEqual(Darwin.link(outside.path, expected.path), 0)

        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [
                TimeMachineRemoteFile(
                    path: "store.sparsebundle/bands/0",
                    logicalSize: 8 * 1_048_576,
                    chunks: []
                )
            ],
            sourceDirectory: source,
            repositoryID: UUID()
        )

        XCTAssertEqual(try Data(contentsOf: outside), protectedData)
        XCTAssertEqual(
            try expected.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            8 * 1_048_576
        )
        var outsideStatus = stat()
        var expectedStatus = stat()
        XCTAssertEqual(Darwin.lstat(outside.path, &outsideStatus), 0)
        XCTAssertEqual(Darwin.lstat(expected.path, &expectedStatus), 0)
        XCTAssertNotEqual(outsideStatus.st_ino, expectedStatus.st_ino)
        XCTAssertEqual(expectedStatus.st_nlink, 1)
    }

    func testPlaceholderRecoveryReplacesMarkerSymlinkWithoutFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-marker-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        let protectedData = Data("do not replace".utf8)
        try protectedData.write(to: outside)
        let marker = source.appendingPathComponent(
            TimeMachineRuntimePaths.repositoryMarkerFileName
        )
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        let repositoryID = UUID()

        try TimeMachineDiskBackend.materializeSparsePlaceholders(
            files: [],
            sourceDirectory: source,
            repositoryID: repositoryID
        )

        XCTAssertEqual(try Data(contentsOf: outside), protectedData)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            repositoryID.uuidString
        )
        var markerStatus = stat()
        XCTAssertEqual(Darwin.lstat(marker.path, &markerStatus), 0)
        XCTAssertEqual(markerStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(markerStatus.st_nlink, 1)
    }

    func testPlaceholderRecoveryRejectsReservedControlNamespace() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-reserved-placeholder-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: source) }

        for path in [
            ".delta-control.sock",
            "store.sparsebundle/.delta-hidden",
            "store.sparsebundle/\(String(repeating: "x", count: 256))",
            String(repeating: "x", count: TimeMachineRemotePathPolicy.maximumPathBytes + 1)
        ] {
            XCTAssertThrowsError(
                try TimeMachineDiskBackend.materializeSparsePlaceholders(
                    files: [
                        TimeMachineRemoteFile(
                            path: path,
                            logicalSize: 1,
                            chunks: []
                        )
                    ],
                    sourceDirectory: source,
                    repositoryID: UUID()
                )
            ) { error in
                XCTAssertEqual(
                    error as? TimeMachineSparseFileSessionError,
                    .invalidPath(path)
                )
            }
        }
    }

    func testPlaceholderRecoveryRejectsNULAndFileDirectoryPrefixCollisions() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-invalid-placeholders-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: source) }

        XCTAssertThrowsError(
            try TimeMachineDiskBackend.materializeSparsePlaceholders(
                files: [
                    TimeMachineRemoteFile(
                        path: "store.sparsebundle/bands/0\0ignored",
                        logicalSize: 1,
                        chunks: []
                    )
                ],
                sourceDirectory: source,
                repositoryID: UUID()
            )
        )
        XCTAssertThrowsError(
            try TimeMachineDiskBackend.materializeSparsePlaceholders(
                files: [
                    TimeMachineRemoteFile(path: "store.sparsebundle/bands", logicalSize: 1, chunks: []),
                    TimeMachineRemoteFile(path: "store.sparsebundle/bands/0", logicalSize: 1, chunks: [])
                ],
                sourceDirectory: source,
                repositoryID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? TimeMachineObjectStoreError, .invalidManifest)
        }
    }

    func testWriterIdentityIsStablePrivateAndRepositoryScoped() throws {
        let supportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-writer-id-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let repositoryID = UUID()

        let first = try TimeMachineRuntimePaths.loadOrCreateWriterID(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        let second = try TimeMachineRuntimePaths.loadOrCreateWriterID(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        let other = try TimeMachineRuntimePaths.loadOrCreateWriterID(
            repositoryID: UUID(),
            applicationSupportURL: supportURL
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        let identityURL = try TimeMachineRuntimePaths.writerIdentityURL(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: identityURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testWriterIdentityRejectsSymlinkInsteadOfFollowingIt() throws {
        let supportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-writer-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let repositoryID = UUID()
        let identityURL = try TimeMachineRuntimePaths.writerIdentityURL(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        try FileManager.default.createDirectory(
            at: identityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outsideURL = supportURL.appendingPathComponent("outside")
        let outsideData = Data(UUID().uuidString.utf8)
        try outsideData.write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: identityURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.loadOrCreateWriterID(
                repositoryID: repositoryID,
                applicationSupportURL: supportURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)
    }

    func testWriterIdentityRejectsHardLinkedIdentity() throws {
        let supportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-writer-hardlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let repositoryID = UUID()
        _ = try TimeMachineRuntimePaths.loadOrCreateWriterID(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        let identityURL = try TimeMachineRuntimePaths.writerIdentityURL(
            repositoryID: repositoryID,
            applicationSupportURL: supportURL
        )
        let outsideLink = supportURL.appendingPathComponent("outside-writer-link")
        try FileManager.default.linkItem(at: identityURL, to: outsideLink)

        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.loadOrCreateWriterID(
                repositoryID: repositoryID,
                applicationSupportURL: supportURL
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideLink.path))
    }

    func testRemovingLocalStateDeletesOnlyTheRequestedRepositoryRuntime() throws {
        let supportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-remove-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let removedID = UUID()
        let retainedID = UUID()
        let removed = try TimeMachineRuntimePaths.cacheDirectory(
            repositoryID: removedID,
            applicationSupportURL: supportURL
        )
        let retained = try TimeMachineRuntimePaths.cacheDirectory(
            repositoryID: retainedID,
            applicationSupportURL: supportURL
        )
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try Data("dirty cache".utf8).write(to: removed.appendingPathComponent("chunk"))
        try Data("keep".utf8).write(to: retained.appendingPathComponent("chunk"))

        try TimeMachineRuntimePaths.removeLocalState(
            repositoryID: removedID,
            applicationSupportURL: supportURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertEqual(
            try Data(contentsOf: retained.appendingPathComponent("chunk")),
            Data("keep".utf8)
        )
    }

    func testFileSystemMountPointUsesCompleteRepositoryIdentity() throws {
        let first = UUID(uuidString: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A")!
        let second = UUID(uuidString: "6A02F7B3-1111-4222-8333-444455556666")!
        let support = URL(fileURLWithPath: "/Users/test/Library/Application Support/Delta")

        let firstMount = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: first,
            applicationSupportURL: support
        )
        let secondMount = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: second,
            applicationSupportURL: support
        )

        XCTAssertNotEqual(firstMount, secondMount)
        XCTAssertEqual(firstMount.lastPathComponent, "filesystem")
        XCTAssertEqual(secondMount.lastPathComponent, "filesystem")
        XCTAssertTrue(firstMount.path.contains(first.uuidString))
        XCTAssertTrue(secondMount.path.contains(second.uuidString))
        XCTAssertFalse(firstMount.path.hasPrefix("/Volumes/"))
    }

    func testFileSystemMountPointBindsConnectionSessionAndReclaimsOnlyEmptyStaleInstances() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-mount-sessions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let repositoryID = UUID()
        let currentSessionID = UUID()
        let staleSessionID = UUID()
        let repository = try TimeMachineRuntimePaths.repositoryDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: repository.path
        )
        let current = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            mountSessionID: currentSessionID,
            applicationSupportURL: support
        )
        let stale = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            mountSessionID: staleSessionID,
            applicationSupportURL: support
        )
        let legacy = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            applicationSupportURL: support
        )
        let nonempty = repository.appendingPathComponent(
            "filesystem-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        for url in [current, stale, legacy, nonempty] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try Data("retain".utf8).write(to: nonempty.appendingPathComponent("evidence"))
        let outside = support.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = repository.appendingPathComponent(
            "filesystem-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try TimeMachineRuntimePaths.removeStaleFileSystemMountPoints(
            repositoryID: repositoryID,
            keeping: currentSessionID,
            applicationSupportURL: support
        )

        XCTAssertEqual(
            current.lastPathComponent,
            "filesystem-\(currentSessionID.uuidString.lowercased())"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonempty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testStagingCleanupIsNoFollowAndLeavesUnrelatedDataUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-staging-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let settings = TimeMachineRepositorySettings(
            storeID: UUID(uuidString: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A")!,
            volumeName: "History"
        )
        let staging = root.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageStagingName(settings: settings),
            isDirectory: true
        )
        let bands = staging.appendingPathComponent("bands", isDirectory: true)
        try FileManager.default.createDirectory(at: bands, withIntermediateDirectories: true)
        try Data("band".utf8).write(to: bands.appendingPathComponent("0"))
        let outside = root.appendingPathComponent("outside")
        try Data("retain".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        try TimeMachineRuntimePaths.removeDiskImageStagingDirectory(
            settings: settings,
            from: root
        )

        XCTAssertFalse(lstatExists(staging.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("retain".utf8))
    }

    func testStagingPromotionIsExclusiveAndCanonical() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-time-machine-staging-promotion-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let settings = TimeMachineRepositorySettings(
            storeID: UUID(uuidString: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A")!,
            volumeName: "History"
        )
        let staging = root.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageStagingName(settings: settings),
            isDirectory: true
        )
        let final = root.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        try TimeMachineRuntimePaths.promoteDiskImageStagingDirectory(
            settings: settings,
            in: root
        )

        XCTAssertFalse(lstatExists(staging.path))
        XCTAssertTrue(lstatExists(final.path))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: final.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o700
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: final.path
        )
        try TimeMachineRuntimePaths.secureDiskImageDirectory(
            settings: settings,
            in: root
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: final.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o700
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try TimeMachineRuntimePaths.promoteDiskImageStagingDirectory(
                settings: settings,
                in: root
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertTrue(lstatExists(staging.path))
        XCTAssertTrue(lstatExists(final.path))
    }

    func testTimeMachineVolumeNamesRejectControlAndPathLikeValues() {
        XCTAssertEqual(
            TimeMachineRepositorySettings.normalizedVolumeName("  Mac History  "),
            "Mac History"
        )
        for invalid in [".", "..", "History\nDisk", "History\u{0}Disk", "History/Old"] {
            XCTAssertNil(TimeMachineRepositorySettings.normalizedVolumeName(invalid))
        }
    }

    private func lstatExists(_ path: String) -> Bool {
        var attributes = stat()
        return lstat(path, &attributes) == 0
    }
}
