import Darwin
import Foundation
import DeltaTimeMachineIPC
import XCTest
@testable import DeltaCore

final class TimeMachineSystemControllerTests: XCTestCase {
    func testSetupDeadlinesUseOneMonotonicBudgetAcrossCommands() {
        let deadline = TimeMachineSetupDeadline(
            duration: 10.25,
            nowUptimeNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(deadline.uptimeNanoseconds, 11_250_000_000)
        XCTAssertEqual(
            deadline.remainingTime(nowUptimeNanoseconds: 7_000_000_000),
            4.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            deadline.remainingTime(nowUptimeNanoseconds: 11_250_000_000),
            0
        )
        XCTAssertEqual(
            deadline.remainingTime(nowUptimeNanoseconds: 12_000_000_000),
            0
        )
    }

    func testSetupClientDeadlineEnclosesOperationAndRollbackBudgets() {
        XCTAssertEqual(TimeMachineSetupExecutionPolicy.operationRuntime, 600)
        XCTAssertEqual(TimeMachineSetupExecutionPolicy.rollbackRuntime, 60)
        XCTAssertGreaterThan(
            TimeMachineSetupExecutionPolicy.clientReplyTimeout,
            TimeMachineSetupExecutionPolicy.operationRuntime
                + TimeMachineSetupExecutionPolicy.rollbackRuntime
        )
        XCTAssertEqual(
            TimeMachineSetupExecutionPolicy.helperReadinessTimeout,
            15
        )
        XCTAssertEqual(TimeMachineSetupExecutionPolicy.maximumRequestBytes, 65_536)
        XCTAssertEqual(TimeMachineSetupExecutionPolicy.maximumPasswordBytes, 4_096)
    }

    func testTimeMachineFullDiskAccessFailureIsNormalizedOnlyForTmutil() {
        let diagnostic = "tmutil: setdestination requires Full Disk Access privileges."

        XCTAssertTrue(
            TimeMachineSetupCommandFailurePolicy.requiresFullDiskAccess(
                executablePath: "/usr/bin/tmutil",
                standardError: diagnostic
            )
        )
        XCTAssertFalse(
            TimeMachineSetupCommandFailurePolicy.requiresFullDiskAccess(
                executablePath: "/usr/bin/hdiutil",
                standardError: diagnostic
            )
        )
        XCTAssertFalse(
            TimeMachineSetupCommandFailurePolicy.requiresFullDiskAccess(
                executablePath: "/usr/bin/tmutil",
                standardError: "setdestination failed with exit 1"
            )
        )
        XCTAssertEqual(
            TimeMachineSetupCommandFailurePolicy.normalizedUserMessage(
                "tmutil: setdestination requires Full Disk Access privileges. Add Terminal."
            ),
            TimeMachineSetupCommandFailurePolicy.fullDiskAccessUserMessage
        )
        XCTAssertEqual(
            TimeMachineSetupCommandFailurePolicy.normalizedUserMessage(
                "The destination is unavailable."
            ),
            "The destination is unavailable."
        )
    }

    func testFullDiskAccessGuideUsesCurrentMacOSPrivacySettingsRoute() {
        XCTAssertEqual(
            FullDiskAccessGuide.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        )
    }

    func testTimeMachineMountCommandForcesFSKitDispatch() {
        XCTAssertEqual(TimeMachineFSKitMountCommand.executable, "/sbin/mount")
        XCTAssertEqual(
            TimeMachineFSKitMountCommand.arguments(
                sourcePath: "/tmp/delta-tm-501-repository",
                mountPoint: "/Volumes/Delta Time Machine Storage-repository"
            ),
            [
                "-F",
                "-k",
                "-w",
                "-t",
                "delta-tm",
                "/tmp/delta-tm-501-repository",
                "/Volumes/Delta Time Machine Storage-repository"
            ]
        )
        XCTAssertTrue(
            TimeMachineMountedFileSystemIdentity.matches(
                reportedSource: "file:///tmp/delta-tm-501-repository",
                expectedSourceURL: URL(fileURLWithPath: "/tmp/delta-tm-501-repository")
            )
        )
        XCTAssertTrue(
            TimeMachineMountedFileSystemIdentity.matches(
                reportedSource: "/tmp/delta-tm-501-repository",
                expectedSourceURL: URL(fileURLWithPath: "/tmp/delta-tm-501-repository")
            )
        )
        XCTAssertFalse(
            TimeMachineMountedFileSystemIdentity.matches(
                reportedSource: "relative/source",
                expectedSourceURL: URL(fileURLWithPath: "/tmp/delta-tm-501-repository")
            )
        )
    }

    func testDestinationInformationParserUsesExactMountedDestination() throws {
        let firstID = "A59D9F3B-02FB-41A0-8466-B360708A26E1"
        let secondID = "19EE5DF2-DBCF-4690-A5C4-B7146550A9A2"
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Destinations": [
                    [
                        "DestinationID": firstID.lowercased(),
                        "MountPoint": "/Volumes/Other"
                    ],
                    [
                        "DestinationIdentifier": secondID,
                        "MountPoint": "/Volumes/History"
                    ],
                    [
                        "DestinationID": "not-a-uuid",
                        "MountPoint": "/Volumes/Invalid"
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )

        let information = try TimeMachineDestinationInformationParser.parse(
            data,
            matchingMountPoint: "/Volumes/History"
        )

        XCTAssertEqual(information.matchingIdentifier, secondID)
        XCTAssertEqual(information.knownIdentifiers, [firstID, secondID])
        XCTAssertThrowsError(
            try TimeMachineDestinationInformationParser.parse(
                Data("not a property list".utf8),
                matchingMountPoint: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDestinationInformationError,
                .invalidPropertyList
            )
        }
    }

    func testAPFSVolumeRoleParserRequiresBackupRoleOnExactDevice() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Containers": [
                    [
                        "Volumes": [
                            [
                                "DeviceIdentifier": "disk41s1",
                                "Roles": ["Data"]
                            ],
                            [
                                "DeviceIdentifier": "disk42s1",
                                "Roles": ["Backup"]
                            ]
                        ]
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )

        XCTAssertTrue(
            try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
                data,
                deviceIdentifier: "disk42s1"
            )
        )
        XCTAssertFalse(
            try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
                data,
                deviceIdentifier: "disk41s1"
            )
        )
        XCTAssertFalse(
            try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
                data,
                deviceIdentifier: "disk99s1"
            )
        )
    }

    func testAPFSVolumeRoleParserFailsClosedForMalformedStructuredOutput() {
        let missingVolumes = try! PropertyListSerialization.data(
            fromPropertyList: ["Containers": [["ContainerReference": "disk42"]]],
            format: .xml,
            options: 0
        )
        for data in [Data("not a property list".utf8), missingVolumes] {
            XCTAssertThrowsError(
                try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
                    data,
                    deviceIdentifier: "disk42s1"
                )
            ) { error in
                XCTAssertEqual(
                    error as? TimeMachineAPFSVolumeRoleError,
                    .invalidPropertyList
                )
            }
        }
    }

    func testPersistedMountedStateRequiresCompleteSystemEvidence() {
        let repositoryID = UUID()
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let destinationID = "B0E7EE4E-9247-4B09-915B-23D704512826"
        let persisted = TimeMachineDestinationState(
            repositoryID: repositoryID,
            storeID: settings.storeID,
            lifecycle: .mounted,
            mountSessionID: UUID(),
            mountPoint: "/Volumes/Stale",
            diskImagePath: "History.sparsebundle",
            deviceIdentifier: "disk90s1",
            timeMachineDestinationID: destinationID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let now = Date(timeIntervalSince1970: 200)

        let connected = TimeMachineSystemStateReconciliationPolicy.reconcile(
            persisted,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .mounted,
                diskImagePresent: true,
                timeMachineMountPoint: "/Volumes/History",
                deviceIdentifier: "disk42s1",
                hasBackupRole: true,
                matchingDestinationIdentifier: destinationID,
                knownDestinationIdentifiers: [destinationID]
            ),
            now: now
        )

        XCTAssertEqual(connected.lifecycle, .mounted)
        XCTAssertEqual(connected.mountPoint, "/Volumes/History")
        XCTAssertEqual(connected.deviceIdentifier, "disk42s1")
        XCTAssertNil(connected.lastError)
        XCTAssertTrue(connected.isReadyForBackup)
        XCTAssertEqual(connected.updatedAt, now)

        let missingBackupRole = TimeMachineSystemStateReconciliationPolicy.reconcile(
            persisted,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .mounted,
                diskImagePresent: true,
                timeMachineMountPoint: "/Volumes/History",
                deviceIdentifier: "disk42s1",
                hasBackupRole: false,
                matchingDestinationIdentifier: destinationID,
                knownDestinationIdentifiers: [destinationID]
            ),
            now: now
        )
        XCTAssertEqual(missingBackupRole.lifecycle, .mounted)
        XCTAssertEqual(
            missingBackupRole.lastFailureContext,
            .systemDisconnection
        )
        XCTAssertTrue(missingBackupRole.blocksConfigurationChanges)

        let absent = TimeMachineSystemStateReconciliationPolicy.reconcile(
            persisted,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .unmounted,
                diskImagePresent: false,
                timeMachineMountPoint: nil,
                deviceIdentifier: nil,
                hasBackupRole: false,
                matchingDestinationIdentifier: nil,
                knownDestinationIdentifiers: []
            ),
            now: now
        )

        XCTAssertEqual(absent.lifecycle, .failed)
        XCTAssertNil(absent.mountPoint)
        XCTAssertNil(absent.deviceIdentifier)
        XCTAssertNil(absent.timeMachineDestinationID)
        XCTAssertEqual(absent.lastFailureContext, .systemConnection)
        XCTAssertEqual(
            TimeMachineDestinationPresentation.make(state: absent).primaryAction,
            .connect
        )
        XCTAssertFalse(TimeMachineDestinationPresentation.make(state: absent).isMounted)
    }

    func testSystemReconciliationPreservesSavedDestinationForReconnect() {
        let settings = TimeMachineRepositorySettings(volumeName: "History")
        let destinationID = "399F3FA0-0154-4ACD-A8A1-D79B5772285B"
        let persisted = TimeMachineDestinationState(
            repositoryID: UUID(),
            storeID: settings.storeID,
            lifecycle: .mounted,
            timeMachineDestinationID: destinationID
        )

        let cleanup = TimeMachineSystemStateReconciliationPolicy.reconcile(
            persisted,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .unmounted,
                diskImagePresent: false,
                timeMachineMountPoint: nil,
                deviceIdentifier: nil,
                hasBackupRole: false,
                matchingDestinationIdentifier: nil,
                knownDestinationIdentifiers: [destinationID]
            ),
            now: Date()
        )
        XCTAssertEqual(cleanup.lifecycle, .failed)
        XCTAssertEqual(cleanup.lastFailureContext, .systemConnection)
        XCTAssertEqual(cleanup.timeMachineDestinationID, destinationID)
        XCTAssertEqual(
            TimeMachineDestinationPresentation.make(state: cleanup).primaryAction,
            .connect
        )

        var intentionallyDisconnected = persisted
        intentionallyDisconnected.lifecycle = .disconnecting
        let disconnected = TimeMachineSystemStateReconciliationPolicy.reconcile(
            intentionallyDisconnected,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .unmounted,
                diskImagePresent: false,
                timeMachineMountPoint: nil,
                deviceIdentifier: nil,
                hasBackupRole: false,
                matchingDestinationIdentifier: nil,
                knownDestinationIdentifiers: [destinationID]
            ),
            now: Date()
        )
        XCTAssertEqual(disconnected.lifecycle, .disconnected)
        XCTAssertEqual(disconnected.timeMachineDestinationID, destinationID)
        XCTAssertNil(disconnected.lastError)
        XCTAssertNil(disconnected.lastFailureContext)

        let partial = TimeMachineSystemStateReconciliationPolicy.reconcile(
            persisted,
            settings: settings,
            observation: TimeMachineSystemDiskObservation(
                fileSystemState: .mounted,
                diskImagePresent: true,
                timeMachineMountPoint: "/Volumes/History",
                deviceIdentifier: "disk42s1",
                hasBackupRole: true,
                matchingDestinationIdentifier: nil,
                knownDestinationIdentifiers: []
            ),
            now: Date()
        )
        XCTAssertEqual(partial.lifecycle, .mounted)
        XCTAssertEqual(partial.lastFailureContext, .systemDisconnection)
        XCTAssertTrue(partial.blocksConfigurationChanges)
        XCTAssertTrue(TimeMachineDestinationPresentation.make(state: partial).isMounted)
        XCTAssertEqual(
            TimeMachineDestinationPresentation.make(state: partial).primaryAction,
            .none
        )
    }

    func testPrivilegedBoundariesRequireExactDeltaTeamAndIdentifier() {
        XCTAssertEqual(DeltaCodeSigningRequirement.teamIdentifier, "BJCVJ5G7MJ")
        XCTAssertEqual(
            DeltaTimeMachineIPCIdentity.teamIdentifier,
            DeltaCodeSigningRequirement.teamIdentifier
        )
        XCTAssertEqual(
            TimeMachineServiceController.codeSigningIdentifier,
            DeltaTimeMachineIPCIdentity.storageServiceIdentifier
        )
        XCTAssertEqual(
            DeltaCodeSigningRequirement.designated(identifier: "com.delta.backup"),
            "anchor apple generic and identifier \"com.delta.backup\" and certificate leaf[subject.OU] = \"BJCVJ5G7MJ\""
        )
    }

    func testTimeMachineSystemFingerprintIsOrderedAndLengthDelimited() {
        let first = TimeMachineSystemRegistrationFingerprint.fingerprint(
            artifacts: [Data("ab".utf8), Data("c".utf8)]
        )
        let same = TimeMachineSystemRegistrationFingerprint.fingerprint(
            artifacts: [Data("ab".utf8), Data("c".utf8)]
        )
        let differentBoundary = TimeMachineSystemRegistrationFingerprint.fingerprint(
            artifacts: [Data("a".utf8), Data("bc".utf8)]
        )
        let differentOrder = TimeMachineSystemRegistrationFingerprint.fingerprint(
            artifacts: [Data("c".utf8), Data("ab".utf8)]
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, differentBoundary)
        XCTAssertNotEqual(first, differentOrder)
    }

    func testTimeMachineSystemFingerprintReadsPackagedExtensionLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-time-machine-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var artifacts: [Data] = []
        for (index, relativePath) in TimeMachineSystemRegistrationFingerprint
            .artifactRelativePaths.enumerated()
        {
            XCTAssertFalse(relativePath.contains("/PlugIns/"))
            if relativePath.contains("DeltaTimeMachineFS") {
                XCTAssertTrue(relativePath.contains("/Extensions/"))
            }
            let artifactURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: artifactURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let artifact = Data("artifact-\(index)".utf8)
            artifacts.append(artifact)
            try artifact.write(to: artifactURL)
        }

        XCTAssertEqual(
            TimeMachineSystemRegistrationFingerprint.current(bundleURL: root),
            TimeMachineSystemRegistrationFingerprint.fingerprint(
                bundlePath: root.standardizedFileURL.resolvingSymlinksInPath().path,
                artifacts: artifacts
            )
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                TimeMachineSystemRegistrationFingerprint.artifactRelativePaths.last!
            )
        )
        XCTAssertNil(TimeMachineSystemRegistrationFingerprint.current(bundleURL: root))
    }

    func testTimeMachineSystemFingerprintBindsInstalledBundlePath() {
        let artifacts = [Data("same-service".utf8), Data("same-helper".utf8)]
        XCTAssertNotEqual(
            TimeMachineSystemRegistrationFingerprint.fingerprint(
                bundlePath: "/Applications/Delta.app",
                artifacts: artifacts
            ),
            TimeMachineSystemRegistrationFingerprint.fingerprint(
                bundlePath: "/Applications/Renamed Delta.app",
                artifacts: artifacts
            )
        )
    }

    func testTimeMachineSystemMutationsRequireCanonicalInstalledApp() {
        XCTAssertTrue(
            TimeMachineInstalledApplicationPolicy.isCanonicalInstallation(
                bundleURL: URL(
                    fileURLWithPath: "/Applications/Delta.app",
                    isDirectory: true
                )
            )
        )
        for path in [
            "/Applications/Delta 0.4.0 Acceptance.app",
            "/Users/test/Applications/Delta.app",
            "/tmp/Delta.app",
            "/Users/test/project/dist/Delta.app",
            "/Users/test/Library/Developer/Xcode/DerivedData/Delta/Build/Products/Release/Delta.app"
        ] {
            XCTAssertFalse(
                TimeMachineInstalledApplicationPolicy.isCanonicalInstallation(
                    bundleURL: URL(fileURLWithPath: path, isDirectory: true)
                ),
                path
            )
        }
    }

    func testTimeMachineSystemMutationsRejectSymlinkAtCanonicalPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "delta-canonical-install-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        let realApp = root.appendingPathComponent("Build/Delta.app", isDirectory: true)
        let canonicalApp = root.appendingPathComponent(
            "Applications/Delta.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realApp,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: canonicalApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: canonicalApp,
            withDestinationURL: realApp
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            TimeMachineInstalledApplicationPolicy.isCanonicalInstallation(
                bundleURL: canonicalApp,
                canonicalBundleURL: canonicalApp
            )
        )
    }

    func testTimeMachineSystemRegistrationRefreshRequiresIdleEnabledDestinations() {
        XCTAssertTrue(
            TimeMachineSystemRegistrationMaintenancePolicy.isCurrent(
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "same",
                currentFingerprint: "same"
            )
        )
        XCTAssertFalse(
            TimeMachineSystemRegistrationMaintenancePolicy.isCurrent(
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "new"
            )
        )
        XCTAssertEqual(
            TimeMachineSystemRegistrationMaintenancePolicy.action(
                hasTimeMachineDestinations: true,
                updateReadiness: .ready,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "new"
            ),
            .reregister
        )
        for readiness in [
            DeltaSoftwareUpdateReadiness.operationInProgress,
            .timeMachineDestinationsConnected(Set([UUID()])),
            .applicationStateUnavailable
        ] {
            XCTAssertEqual(
                TimeMachineSystemRegistrationMaintenancePolicy.action(
                    hasTimeMachineDestinations: true,
                    updateReadiness: readiness,
                    serviceStatus: .enabled,
                    helperStatus: .enabled,
                    registeredFingerprint: "old",
                    currentFingerprint: "new"
                ),
                .none
            )
        }
        XCTAssertEqual(
            TimeMachineSystemRegistrationMaintenancePolicy.action(
                hasTimeMachineDestinations: true,
                updateReadiness: .ready,
                serviceStatus: .requiresApproval,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "new"
            ),
            .none
        )
        XCTAssertEqual(
            TimeMachineSystemRegistrationMaintenancePolicy.action(
                hasTimeMachineDestinations: true,
                updateReadiness: .ready,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "new",
                currentFingerprint: "new"
            ),
            .none
        )
    }

    func testCodeSigningIdentityMatchesCurrentTestExecutable() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        XCTAssertEqual(
            try DeltaCodeSigningIdentity.currentProcessCodeHash(),
            try DeltaCodeSigningIdentity.staticCodeHash(at: executable)
        )
        let signedExecutable = try DeltaCodeSigningIdentity
            .currentProcessExecutableURL()
        XCTAssertTrue(signedExecutable.isFileURL)
        XCTAssertEqual(
            try DeltaCodeSigningIdentity.currentProcessCodeHash(),
            try DeltaCodeSigningIdentity.staticCodeHash(at: signedExecutable)
        )
    }

    func testCodeSigningPeerHashMustMatchExactInstalledComponent() {
        let expected = Data(repeating: 0x11, count: 20)
        XCTAssertTrue(
            DeltaCodeSigningPeerValidator.matches(
                expectedCodeHash: expected,
                observedCodeHash: expected
            )
        )
        XCTAssertFalse(
            DeltaCodeSigningPeerValidator.matches(
                expectedCodeHash: expected,
                observedCodeHash: Data(repeating: 0x22, count: 20)
            )
        )
        XCTAssertFalse(
            DeltaCodeSigningPeerValidator.matches(
                expectedCodeHash: Data(),
                observedCodeHash: Data()
            )
        )
    }

    func testSetupHelperReadinessRequiresExactNonemptyCodeHash() {
        let expected = Data(repeating: 0x11, count: 20)
        XCTAssertTrue(
            TimeMachineSetupHelperReadinessPolicy.isCurrent(
                expectedCodeHash: expected,
                observedCodeHash: expected
            )
        )
        XCTAssertFalse(
            TimeMachineSetupHelperReadinessPolicy.isCurrent(
                expectedCodeHash: expected,
                observedCodeHash: Data(repeating: 0x22, count: 20)
            )
        )
        XCTAssertFalse(
            TimeMachineSetupHelperReadinessPolicy.isCurrent(
                expectedCodeHash: Data(),
                observedCodeHash: Data()
            )
        )
        let roundTrip = TimeMachineSetupHelperReadiness(codeHash: expected)
        XCTAssertEqual(
            try? JSONDecoder().decode(
                TimeMachineSetupHelperReadiness.self,
                from: JSONEncoder().encode(roundTrip)
            ),
            roundTrip
        )
    }

    func testInstalledComponentLayoutFindsOnlyAnEnclosingApplicationBundle() {
        XCTAssertEqual(
            TimeMachineInstalledComponentLayout.applicationBundleURL(
                containingExecutable: URL(
                    fileURLWithPath: "/Applications/Delta.app/Contents/Resources/DeltaTimeMachineService"
                )
            ),
            URL(fileURLWithPath: "/Applications/Delta.app", isDirectory: true)
        )
        XCTAssertNil(
            TimeMachineInstalledComponentLayout.applicationBundleURL(
                containingExecutable: URL(fileURLWithPath: "/usr/local/bin/Delta")
            )
        )
    }

    func testTimeMachineHelperUsesCurrentServiceManagementExecutableLayout() {
        XCTAssertEqual(
            TimeMachineSetupHelperController.executableRelativePath,
            "Contents/MacOS/DeltaTimeMachineHelper"
        )
        XCTAssertFalse(
            TimeMachineSetupHelperController.executableRelativePath.contains(
                "Contents/Library/LaunchServices"
            )
        )
    }

    func testTimeMachineSystemAccessTreatsPendingApprovalAsAcceptedRegistration() {
        XCTAssertTrue(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .enabled)
        )
        XCTAssertTrue(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .requiresApproval)
        )
        XCTAssertFalse(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .notRegistered)
        )
        XCTAssertFalse(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .notFound)
        )
        XCTAssertFalse(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .unavailable)
        )
        XCTAssertFalse(
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: .unknown("future"))
        )
    }

    func testServiceManagementReregistrationRetriesOnlyTheUnsettledState() {
        XCTAssertEqual(
            ServiceManagementReregistrationPolicy.retryDelay(
                afterFailedAttempt: 0,
                status: .notRegistered
            ),
            .milliseconds(250)
        )
        XCTAssertEqual(
            ServiceManagementReregistrationPolicy.retryDelay(
                afterFailedAttempt: 1,
                status: .notRegistered
            ),
            .milliseconds(500)
        )
        XCTAssertEqual(
            ServiceManagementReregistrationPolicy.retryDelay(
                afterFailedAttempt: 2,
                status: .notRegistered
            ),
            .seconds(1)
        )
        XCTAssertNil(
            ServiceManagementReregistrationPolicy.retryDelay(
                afterFailedAttempt: 3,
                status: .notRegistered
            )
        )

        for status in [
            LaunchAgentRegistrationStatus.enabled,
            .requiresApproval,
            .notFound,
            .unavailable,
            .unknown("future")
        ] {
            XCTAssertNil(
                ServiceManagementReregistrationPolicy.retryDelay(
                    afterFailedAttempt: 0,
                    status: status
                )
            )
        }
    }

    func testExplicitTimeMachineSystemAccessRepairsOnlyStaleEnabledRegistration() {
        XCTAssertEqual(
            TimeMachineSystemAccessRequestPolicy.action(
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .reregister
        )
        XCTAssertEqual(
            TimeMachineSystemAccessRequestPolicy.action(
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "current",
                currentFingerprint: "current"
            ),
            .none
        )
        XCTAssertEqual(
            TimeMachineSystemAccessRequestPolicy.action(
                serviceStatus: .notRegistered,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .register
        )
        XCTAssertEqual(
            TimeMachineSystemAccessRequestPolicy.action(
                serviceStatus: .enabled,
                helperStatus: .requiresApproval,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .none
        )
        XCTAssertEqual(
            TimeMachineSystemAccessRequestPolicy.action(
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: nil
            ),
            .none
        )
    }

    func testPostRegistrationRepairPreservesFreshlyRegisteredComponents() {
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .enabled,
                priorHelperStatus: .notRegistered,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .repair(.backgroundService)
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .notRegistered,
                priorHelperStatus: .enabled,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .repair(.setupHelper)
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .notRegistered,
                priorHelperStatus: .notRegistered,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .recordCurrentFingerprint
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .enabled,
                priorHelperStatus: .enabled,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .repair(.all)
        )
    }

    func testPostRegistrationRepairWaitsForApprovalAndCompleteEvidence() {
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .enabled,
                priorHelperStatus: .notRegistered,
                serviceStatus: .enabled,
                helperStatus: .requiresApproval,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .repair(.backgroundService)
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .enabled,
                priorHelperStatus: .enabled,
                serviceStatus: .enabled,
                helperStatus: .requiresApproval,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .none
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .notRegistered,
                priorHelperStatus: .notRegistered,
                serviceStatus: .enabled,
                helperStatus: .enabled,
                registeredFingerprint: nil,
                currentFingerprint: nil
            ),
            .none
        )
        XCTAssertEqual(
            TimeMachineSystemAccessPostRegistrationPolicy.action(
                priorServiceStatus: .notRegistered,
                priorHelperStatus: .notRegistered,
                serviceStatus: .enabled,
                helperStatus: .notRegistered,
                registeredFingerprint: nil,
                currentFingerprint: "current"
            ),
            .none
        )
    }

    func testFileSystemExtensionReadinessBindsExactInstalledURL() {
        let expected = URL(
            fileURLWithPath: "/Applications/Delta.app/Contents/Extensions/DeltaTimeMachineFS.appex"
        )
        let other = URL(
            fileURLWithPath: "/tmp/Old Delta.app/Contents/Extensions/DeltaTimeMachineFS.appex"
        )
        let exact = TimeMachineFileSystemModuleObservation(
            bundleIdentifier: TimeMachineFileSystemExtensionProbe.bundleIdentifier,
            url: expected,
            isEnabled: true
        )

        XCTAssertEqual(
            TimeMachineFileSystemExtensionProbe.status(
                observations: [exact],
                expectedURL: expected
            ),
            .enabled
        )
        XCTAssertEqual(
            TimeMachineFileSystemExtensionProbe.status(
                observations: [
                    TimeMachineFileSystemModuleObservation(
                        bundleIdentifier: exact.bundleIdentifier,
                        url: expected,
                        isEnabled: false
                    )
                ],
                expectedURL: expected
            ),
            .disabled
        )
        guard case .unavailable = TimeMachineFileSystemExtensionProbe.status(
            observations: [
                TimeMachineFileSystemModuleObservation(
                    bundleIdentifier: exact.bundleIdentifier,
                    url: other,
                    isEnabled: true
                )
            ],
            expectedURL: expected
        ) else {
            return XCTFail("A same-identifier module from another app must not be accepted.")
        }
        XCTAssertEqual(
            TimeMachineFileSystemExtensionProbe.status(
                observations: [],
                expectedURL: expected
            ),
            .notInstalled
        )
    }

    func testTimeMachineSystemRegistrationAttemptsOncePerInstalledFingerprint() {
        XCTAssertTrue(
            TimeMachineSystemRegistrationRetryPolicy.shouldAttempt(
                currentFingerprint: "new",
                lastAttemptFingerprint: "old"
            )
        )
        XCTAssertFalse(
            TimeMachineSystemRegistrationRetryPolicy.shouldAttempt(
                currentFingerprint: "new",
                lastAttemptFingerprint: "new"
            )
        )
        XCTAssertTrue(
            TimeMachineSystemRegistrationRetryPolicy.shouldAttempt(
                currentFingerprint: "new",
                lastAttemptFingerprint: nil
            )
        )
    }

    func testTimeMachineSystemRegistrationFailureEventsOnlyRecordChanges() {
        let firstFailure = "Time Machine system support could not be refreshed."
        XCTAssertTrue(
            TimeMachineSystemRegistrationEventPolicy.shouldRecordFailure(
                previousMessage: nil,
                currentMessage: firstFailure
            )
        )
        XCTAssertFalse(
            TimeMachineSystemRegistrationEventPolicy.shouldRecordFailure(
                previousMessage: firstFailure,
                currentMessage: firstFailure
            )
        )
        XCTAssertTrue(
            TimeMachineSystemRegistrationEventPolicy.shouldRecordFailure(
                previousMessage: firstFailure,
                currentMessage: "The helper now requires approval."
            )
        )
    }

    func testPrivilegedSetupRequestNeverCarriesDiskPassword() throws {
        let mountSessionID = UUID()
        let register = TimeMachineSetupRequest(
            operation: .registerDestination,
            repositoryID: UUID(),
            mountSessionID: mountSessionID,
            storeID: UUID(),
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776
        )
        let registerObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(register))
                as? [String: Any]
        )
        XCTAssertNil(registerObject["encryptionPassword"])
        XCTAssertNil(registerObject["deviceIdentifier"])
        XCTAssertEqual(registerObject["mountSessionID"] as? String, mountSessionID.uuidString)

        let remove = TimeMachineSetupRequest(
            operation: .removeDestination,
            repositoryID: UUID(),
            storeID: UUID(),
            volumeName: "History",
            imageCapacityBytes: 1_099_511_627_776,
            timeMachineDestinationID: UUID().uuidString
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(remove))
                as? [String: Any]
        )
        XCTAssertNil(object["encryptionPassword"])
        XCTAssertNil(object["deviceIdentifier"])
    }

    func testSetupFailurePreservesObservedResidualMountState() throws {
        let failure = TimeMachineSetupFailure(
            message: "Rollback did not finish.",
            fileSystemState: .mounted
        )
        let decoded = try JSONDecoder().decode(
            TimeMachineSetupFailure.self,
            from: JSONEncoder().encode(failure)
        )
        let clientError = TimeMachineSetupClientError.operationFailed(
            message: decoded.message,
            fileSystemState: decoded.fileSystemState
        )

        XCTAssertEqual(decoded, failure)
        XCTAssertEqual(clientError.fileSystemState, .mounted)
        XCTAssertEqual(clientError.localizedDescription, "Rollback did not finish.")
        XCTAssertNil(TimeMachineSetupClientError.timedOut.fileSystemState)
    }

    func testDestinationRemovalUsesOnlyIdentifierMatchedToAttachedDisk() throws {
        let mounted = "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"
        let stale = "1CB086D4-B3B8-4991-A409-F25388364945"

        XCTAssertEqual(
            try TimeMachineDestinationRemovalPolicy.decision(
                requestedIdentifier: stale,
                mountedIdentifier: mounted.lowercased(),
                knownIdentifiers: [mounted, stale]
            ),
            TimeMachineDestinationRemovalDecision(
                identifierToRemove: mounted,
                hasUnresolvedSavedDestination: true
            )
        )
    }

    func testDestinationRegistrationRejectsDuplicateWhenSavedDestinationIsStillKnown() {
        let requested = "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"

        XCTAssertThrowsError(
            try TimeMachineDestinationRegistrationPolicy.decision(
                requestedIdentifier: requested,
                mountedIdentifier: nil,
                knownIdentifiers: [requested]
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDestinationIdentityPolicyError,
                .destinationIdentityCannotBeVerified
            )
        }
    }

    func testDestinationRegistrationRejectsDifferentMatchedDiskWhileSavedDestinationStillExists() {
        let requested = "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"
        let mounted = "1CB086D4-B3B8-4991-A409-F25388364945"

        XCTAssertThrowsError(
            try TimeMachineDestinationRegistrationPolicy.decision(
                requestedIdentifier: requested,
                mountedIdentifier: mounted,
                knownIdentifiers: [requested, mounted]
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDestinationIdentityPolicyError,
                .destinationIdentityCannotBeVerified
            )
        }
    }

    func testDestinationRegistrationCanAddAfterSavedDestinationWasRemoved() throws {
        XCTAssertEqual(
            try TimeMachineDestinationRegistrationPolicy.decision(
                requestedIdentifier: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A",
                mountedIdentifier: nil,
                knownIdentifiers: []
            ),
            .addDestination
        )
    }

    func testDestinationRemovalRejectsPersistedIdentifierWithoutAttachedProof() {
        let requested = "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"

        XCTAssertThrowsError(
            try TimeMachineDestinationRemovalPolicy.decision(
                requestedIdentifier: requested,
                mountedIdentifier: nil,
                knownIdentifiers: [requested]
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDestinationIdentityPolicyError,
                .destinationIdentityCannotBeVerified
            )
        }
    }

    func testDestinationRemovalTreatsMissingPersistedIdentifierAsAlreadyRemoved() throws {
        XCTAssertEqual(
            try TimeMachineDestinationRemovalPolicy.decision(
                requestedIdentifier: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A",
                mountedIdentifier: nil,
                knownIdentifiers: []
            ),
            TimeMachineDestinationRemovalDecision(
                identifierToRemove: nil,
                hasUnresolvedSavedDestination: false
            )
        )
    }

    func testDestinationRemovalRejectsMalformedIdentifier() {
        XCTAssertThrowsError(
            try TimeMachineDestinationRemovalPolicy.decision(
                requestedIdentifier: "--rotation",
                mountedIdentifier: nil,
                knownIdentifiers: []
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDestinationIdentityPolicyError,
                .invalidDestinationIdentifier
            )
        }
    }

    func testDiskProtocolUsesKernelAuditTokenAndSerializesLifecycle() throws {
        let repositoryID = UUID()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "dtm-ipc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let tokenCapture = AuditTokenCapture()
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { token in
                tokenCapture.record(token)
                return token.count == 32
            }
        ) { request, _ in
            XCTAssertEqual(request.operation, .status)
            XCTAssertEqual(request.repositoryID, repositoryID)
            return TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(repositoryID: repositoryID, generation: 7)
            )
        }

        try server.start()
        try server.start()
        defer {
            server.stop()
            server.stop()
        }
        let client = TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: { $0.count == 32 }
        )
        let result = try client.perform(
            TimeMachineDiskRequest(operation: .status)
        )

        XCTAssertEqual(result.response.generation, 7)
        XCTAssertEqual(tokenCapture.value?.count, 32)

        server.stop()
        XCTAssertThrowsError(
            try client.perform(TimeMachineDiskRequest(operation: .status))
        )
        try server.start()
        XCTAssertEqual(
            try client.perform(TimeMachineDiskRequest(operation: .status)).response.generation,
            7
        )
    }

    func testDiskProtocolServerSurvivesPeerClosingBeforeLargeReply() throws {
        let repositoryID = UUID()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "dtm-pipe-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let handlerStarted = DispatchSemaphore(value: 0)
        let allowReply = DispatchSemaphore(value: 0)
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { $0.count == 32 }
        ) { request, _ in
            if request.operation == .read {
                handlerStarted.signal()
                _ = allowReply.wait(timeout: .now() + 2)
                return TimeMachineDiskProtocolResult(
                    response: TimeMachineDiskResponse(
                        repositoryID: repositoryID,
                        payloadLength: 2 * 1_048_576
                    ),
                    payload: Data(repeating: 0x5A, count: 2 * 1_048_576)
                )
            }
            return TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(repositoryID: repositoryID, generation: 8)
            )
        }
        try server.start()
        defer { server.stop() }

        let descriptor = try connectRawUnixSocket(path: socketPath)
        try writeRawRequest(
            TimeMachineDiskRequest(
                operation: .read,
                repositoryID: repositoryID,
                path: "disk.sparsebundle/bands/0",
                offset: 0,
                length: 1
            ),
            to: descriptor
        )
        XCTAssertEqual(handlerStarted.wait(timeout: .now() + 2), .success)
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
        allowReply.signal()
        Thread.sleep(forTimeInterval: 0.05)

        let result = try TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: { $0.count == 32 }
        ).perform(
            TimeMachineDiskRequest(operation: .status)
        )
        XCTAssertEqual(result.response.generation, 8)
    }

    func testDiskProtocolClientRetriesOneDroppedReplyWithExactRequest() throws {
        let repositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-reply-retry-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let server = try OneReplyDropUnixServer(
            socketPath: socketPath,
            repositoryID: repositoryID
        )
        defer { server.stop() }
        server.start()

        let request = TimeMachineDiskRequest(
            operation: .rename,
            path: "disk.sparsebundle/bands/0",
            destinationPath: "disk.sparsebundle/bands/1"
        )
        let result = try TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: { $0.count == 32 }
        ).perform(request)

        XCTAssertEqual(result.response.generation, 12)
        var authenticatedRequest = request
        authenticatedRequest.repositoryID = repositoryID
        XCTAssertEqual(
            server.waitForRequests(),
            [authenticatedRequest, authenticatedRequest]
        )
    }

    func testDiskProtocolClientRejectsUnauthenticatedServerBeforeSendingRequest() throws {
        let repositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-server-auth-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let handlerCalled = LockedFlag()
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            handlerCalled.set()
            return TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }
        try server.start()
        defer { server.stop() }

        let client = TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: { _ in false }
        )
        XCTAssertThrowsError(
            try client.perform(TimeMachineDiskRequest(operation: .status))
        ) { error in
            XCTAssertEqual(error as? TimeMachineDiskProtocolError, .unauthorizedPeer)
        }
        XCTAssertFalse(handlerCalled.value)
    }

    func testDiskProtocolRejectsAuthenticatedServiceForDifferentRepository() throws {
        let expectedRepositoryID = UUID()
        let actualRepositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-repository-auth-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = TimeMachineDiskProtocolServer(
            socketPath: directory.appendingPathComponent("storage.sock").path,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(repositoryID: actualRepositoryID)
            )
        }
        try server.start()
        defer { server.stop() }

        let client = TimeMachineDiskProtocolClient(
            socketPath: directory.appendingPathComponent("storage.sock").path,
            repositoryID: expectedRepositoryID,
            peerValidator: { $0.count == 32 }
        )
        XCTAssertThrowsError(
            try client.perform(TimeMachineDiskRequest(operation: .status))
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDiskProtocolError,
                .unexpectedRepository(
                    expected: expectedRepositoryID,
                    actual: actualRepositoryID
                )
            )
        }
    }

    func testDiskProtocolClientRejectsAuthenticatedServiceWithDifferentVersion() throws {
        let repositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-version-auth-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(
                    protocolVersion: TimeMachineDiskProtocolVersion.current + 1,
                    repositoryID: repositoryID
                )
            )
        }
        try server.start()
        defer { server.stop() }

        let client = TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: { $0.count == 32 }
        )
        XCTAssertThrowsError(
            try client.perform(TimeMachineDiskRequest(operation: .status))
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineDiskProtocolError,
                .incompatibleVersion(
                    expected: TimeMachineDiskProtocolVersion.current,
                    actual: TimeMachineDiskProtocolVersion.current + 1
                )
            )
        }
    }

    func testDiskProtocolServerRejectsDifferentRequestVersionBeforeHandler() throws {
        let repositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-request-version-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let handlerCalled = LockedFlag()
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            handlerCalled.set()
            return TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }
        try server.start()
        defer { server.stop() }

        let descriptor = try connectRawUnixSocket(path: socketPath)
        defer { _ = Darwin.close(descriptor) }
        try writeRawRequest(
            TimeMachineDiskRequest(
                operation: .status,
                protocolVersion: TimeMachineDiskProtocolVersion.current + 1,
                repositoryID: repositoryID
            ),
            to: descriptor
        )
        let response = try readRawResponse(from: descriptor)

        XCTAssertEqual(response.protocolVersion, TimeMachineDiskProtocolVersion.current)
        XCTAssertEqual(response.repositoryID, repositoryID)
        XCTAssertEqual(response.errorNumber, EPROTONOSUPPORT)
        XCTAssertFalse(handlerCalled.value)
    }

    func testDiskProtocolServerRejectsMismatchedPayloadBeforeHandler() throws {
        let repositoryID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-request-payload-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("storage.sock").path
        let handlerCalled = LockedFlag()
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketPath,
            peerValidator: { $0.count == 32 }
        ) { _, _ in
            handlerCalled.set()
            return TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }
        try server.start()
        defer { server.stop() }

        let descriptor = try connectRawUnixSocket(path: socketPath)
        defer { _ = Darwin.close(descriptor) }
        try writeRawRequest(
            TimeMachineDiskRequest(
                operation: .write,
                repositoryID: repositoryID,
                path: "disk.sparsebundle/bands/0",
                offset: 0,
                payloadLength: 1
            ),
            to: descriptor
        )
        let response = try readRawResponse(from: descriptor)

        XCTAssertEqual(response.repositoryID, repositoryID)
        XCTAssertEqual(response.errorNumber, EPROTO)
        XCTAssertFalse(handlerCalled.value)
    }

    func testDiskProtocolServerPreservesConflictingNonSocketPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-socket-conflict-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("storage.sock")
        let sentinel = Data("do not remove".utf8)
        try sentinel.write(to: socketURL)
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketURL.path,
            peerValidator: { _ in true }
        ) { _, _ in
            TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }

        XCTAssertThrowsError(try server.start())
        server.stop()
        XCTAssertEqual(try Data(contentsOf: socketURL), sentinel)
    }

    func testDiskProtocolServerDoesNotUnlinkReplacementAtShutdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dtm-socket-replacement-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("storage.sock")
        let server = TimeMachineDiskProtocolServer(
            socketPath: socketURL.path,
            peerValidator: { _ in true }
        ) { _, _ in
            TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }
        try server.start()
        XCTAssertEqual(Darwin.unlink(socketURL.path), 0)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: socketURL)

        server.stop()

        XCTAssertEqual(try Data(contentsOf: socketURL), replacement)
    }

    func testStartBackupTargetsOnlyRequestedDestinationInAutomaticMode() throws {
        let runner = TimeMachineSystemRunner()
        let identifier = "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"

        try TimeMachineSystemController(runner: runner).startBackup(
            destinationIdentifier: identifier
        )

        XCTAssertEqual(runner.executableURL?.path, "/usr/bin/tmutil")
        XCTAssertEqual(
            runner.arguments,
            ["startbackup", "--auto", "--destination", identifier]
        )
        XCTAssertNil(runner.standardInput)
    }

    private func connectRawUnixSocket(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard !path.isEmpty, path.utf8.count < capacity else {
                throw POSIXError(.ENAMETOOLONG)
            }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
                    path.withCString { source in
                        strncpy(characters, source, capacity - 1)
                    }
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func writeRawRequest(
        _ request: TimeMachineDiskRequest,
        to descriptor: Int32
    ) throws {
        let header = try JSONEncoder().encode(request)
        var headerLength = UInt32(header.count).bigEndian
        var payloadLength = UInt32(0).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &headerLength) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLength) { frame.append(contentsOf: $0) }
        frame.append(header)
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    private func readRawResponse(from descriptor: Int32) throws -> TimeMachineDiskResponse {
        let lengths = try readExactly(8, from: descriptor)
        let headerLength = lengths.prefix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let payloadLength = lengths.suffix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        XCTAssertEqual(payloadLength, 0)
        let header = try readExactly(Int(headerLength), from: descriptor)
        return try JSONDecoder().decode(TimeMachineDiskResponse.self, from: header)
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < count {
                let received = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if received < 0, errno == EINTR { continue }
                guard received > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                offset += received
            }
        }
        return data
    }

    func testStartBackupRejectsAmbiguousDestinationIdentifierBeforeProcessLaunch() {
        let runner = TimeMachineSystemRunner()

        XCTAssertThrowsError(
            try TimeMachineSystemController(runner: runner).startBackup(
                destinationIdentifier: "--rotation"
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineSystemControllerError,
                .invalidDestinationIdentifier
            )
        }
        XCTAssertNil(runner.executableURL)
    }

    func testStartBackupPreservesCommandFailure() {
        let runner = TimeMachineSystemRunner(
            result: TimeMachineBinaryProcessResult(
                exitCode: 4,
                standardOutput: Data(),
                standardError: "Destination is unavailable"
            )
        )

        XCTAssertThrowsError(
            try TimeMachineSystemController(runner: runner).startBackup(
                destinationIdentifier: "6A02F7B3-E3D0-4B84-89A1-C2E9127F9B5A"
            )
        ) { error in
            XCTAssertEqual(
                error as? TimeMachineSystemControllerError,
                .commandFailed(exitCode: 4, message: "Destination is unavailable")
            )
        }
    }
}

private final class OneReplyDropUnixServer: @unchecked Sendable {
    private let socketPath: String
    private let repositoryID: UUID
    private let stateLock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var listener: Int32
    private var requests: [TimeMachineDiskRequest] = []

    init(socketPath: String, repositoryID: UUID) throws {
        self.socketPath = socketPath
        self.repositoryID = repositoryID
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard !socketPath.isEmpty, socketPath.utf8.count < capacity else {
                throw POSIXError(.ENAMETOOLONG)
            }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
                    socketPath.withCString { source in
                        strncpy(characters, source, capacity - 1)
                    }
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bound == 0, Darwin.listen(descriptor, 2) == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            listener = descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        stop()
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serveTwoRequests()
        }
    }

    func stop() {
        let descriptor = stateLock.withLock { () -> Int32 in
            let current = listener
            listener = -1
            return current
        }
        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
        _ = Darwin.unlink(socketPath)
    }

    func waitForRequests() -> [TimeMachineDiskRequest] {
        _ = completion.wait(timeout: .now() + 2)
        return stateLock.withLock { requests }
    }

    private func serveTwoRequests() {
        defer { completion.signal() }
        for index in 0..<2 {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            do {
                let request = try readRequest(from: descriptor)
                stateLock.withLock { requests.append(request) }
                if index == 0 {
                    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                    _ = Darwin.close(descriptor)
                    continue
                }
                try writeResponse(
                    TimeMachineDiskResponse(
                        repositoryID: repositoryID,
                        generation: 12
                    ),
                    to: descriptor
                )
            } catch {
                _ = Darwin.close(descriptor)
                return
            }
            _ = Darwin.close(descriptor)
        }
    }

    private func readRequest(from descriptor: Int32) throws -> TimeMachineDiskRequest {
        let lengths = try readExactly(8, from: descriptor)
        let headerLength = lengths.prefix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let payloadLength = lengths.suffix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let header = try readExactly(Int(headerLength), from: descriptor)
        _ = try readExactly(Int(payloadLength), from: descriptor)
        return try JSONDecoder().decode(TimeMachineDiskRequest.self, from: header)
    }

    private func writeResponse(
        _ response: TimeMachineDiskResponse,
        to descriptor: Int32
    ) throws {
        let header = try JSONEncoder().encode(response)
        var headerLength = UInt32(header.count).bigEndian
        var payloadLength = UInt32(0).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &headerLength) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLength) { frame.append(contentsOf: $0) }
        frame.append(header)
        try frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < count {
                let received = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if received < 0, errno == EINTR { continue }
                guard received > 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                offset += received
            }
        }
        return data
    }
}

private final class TimeMachineSystemRunner: TimeMachineBinaryProcessRunning, @unchecked Sendable {
    private let result: TimeMachineBinaryProcessResult
    private(set) var executableURL: URL?
    private(set) var arguments: [String] = []
    private(set) var standardInput: Data?

    init(
        result: TimeMachineBinaryProcessResult = TimeMachineBinaryProcessResult(
            exitCode: 0,
            standardOutput: Data(),
            standardError: ""
        )
    ) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        maximumOutputBytes: Int,
        maximumRuntime: TimeInterval
    ) throws -> TimeMachineBinaryProcessResult {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        return result
    }
}

private final class AuditTokenCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ value: Data) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.withLock { stored }
    }

    func set() {
        lock.withLock { stored = true }
    }
}
