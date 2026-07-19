import DeltaTimeMachineIPC
import Foundation

public struct RcloneExecutableLocator: Sendable {
    public init() {}

    public func locate(in bundle: Bundle = .main) -> URL {
        if let bundled = bundle.url(forAuxiliaryExecutable: "rclone") {
            return bundled
        }
        if let resource = bundle.url(forResource: "rclone", withExtension: nil) {
            return resource
        }
        let restic = ResticExecutableLocator().locate(in: bundle)
        let sibling = restic.deletingLastPathComponent().appendingPathComponent("rclone")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        for path in ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return sibling
    }
}

public enum TimeMachineDestinationManagerError: Error, Equatable, LocalizedError, Sendable {
    case notTimeMachineDestination
    case missingSettings
    case invalidManifestSecret
    case invalidDiskPassword
    case destinationBusy
    case requiresDisconnectedDisk
    case destinationNotReadyForConnection
    case destinationNotConnected
    case connectedButStateNotSaved
    case disconnectedButStateNotSaved
    case connectionRollbackIncomplete
    case disconnectionInterrupted
    case systemStateCannotBeVerified
    case systemDiskNoLongerConnected
    case storageServiceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notTimeMachineDestination:
            "This destination does not use the Time Machine format."
        case .missingSettings:
            "The Time Machine destination settings are missing."
        case .invalidManifestSecret:
            "Delta could not authenticate this Time Machine disk because its saved manifest key is missing or invalid."
        case .invalidDiskPassword:
            "The saved Time Machine disk password is empty or exceeds Delta's 4 KiB safety limit. Save a shorter password, then try again."
        case .destinationBusy:
            "This destination is busy with another backup, restore, or maintenance operation."
        case .requiresDisconnectedDisk:
            "Disconnect this Time Machine disk before verifying or repairing its remote storage."
        case .destinationNotReadyForConnection:
            "Repair and verify this Time Machine destination before connecting its disk."
        case .destinationNotConnected:
            "This Time Machine disk is not connected."
        case .connectedButStateNotSaved:
            "The Time Machine disk is connected, but Delta could not save all of its connection state. Disconnect it before changing or removing this destination."
        case .disconnectedButStateNotSaved:
            "The Time Machine disk was disconnected, but Delta could not finish recording the result. Refresh or reopen Delta; if it still appears connected, choose Disconnect again."
        case .connectionRollbackIncomplete:
            "The connection did not finish, and Delta could not confirm that the Time Machine disk was removed. Choose Disconnect before trying again."
        case .disconnectionInterrupted:
            "Delta stopped before it could confirm that the Time Machine disk was disconnected. Choose Disconnect again to finish safely."
        case .systemStateCannotBeVerified:
            "Delta could not verify every part of this Time Machine disk against macOS. Disconnect it again before changing this destination."
        case .systemDiskNoLongerConnected:
            "macOS no longer has this Time Machine disk connected. Connect it again before starting another backup."
        case let .storageServiceUnavailable(message):
            "Delta's Time Machine storage service could not open this destination: \(message)"
        }
    }
}

public enum TimeMachineGenerationContinuityError: Error, Equatable, LocalizedError, Sendable {
    case localStoreIdentityMismatch
    case missingRemoteGeneration(minimumExpected: UInt64)
    case remoteGenerationRollback(minimumExpected: UInt64, actual: UInt64)
    case remoteManifestMismatch(generation: UInt64)
    case committedManifestNotRetained(generation: UInt64)

    public var errorDescription: String? {
        switch self {
        case .localStoreIdentityMismatch:
            "Delta's saved Time Machine disk identity does not match this destination. Reconnect the original disk instead of repairing this one."
        case let .missingRemoteGeneration(minimumExpected):
            "The remote Time Machine history is missing Delta's last committed generation \(minimumExpected). Restore the destination to a provider version containing generation \(minimumExpected) or later, then check it again."
        case let .remoteGenerationRollback(minimumExpected, actual):
            "The remote Time Machine history stops at generation \(actual), but this Mac last committed generation \(minimumExpected). Restore the destination to a provider version containing generation \(minimumExpected) or later, then check it again."
        case let .remoteManifestMismatch(generation):
            "Remote Time Machine generation \(generation) is not the authenticated generation this Mac last committed. Restore the destination to the matching provider version, then check it again."
        case let .committedManifestNotRetained(generation):
            "The remote Time Machine history no longer contains the authenticated generation \(generation) this Mac last committed. Restore the destination to a provider version containing that generation and its later history, then check it again."
        }
    }
}

/// The persisted generation and manifest digest are Delta's local rollback
/// witness. Maintenance, repair, and FSKit startup may move that witness
/// forward after authenticating a newer, contiguous remote history, but must
/// never move it backward or onto a same-generation fork. This check runs
/// before leases, history pruning, garbage collection, placeholder creation,
/// or cache mutation.
public enum TimeMachineGenerationContinuityPolicy {
    public static func validate(
        remoteHistory: [TimeMachineGenerationHead],
        persistedState: TimeMachineDestinationState?,
        expectedStoreID: UUID
    ) throws {
        guard let persistedState else { return }
        guard persistedState.storeID == expectedStoreID else {
            throw TimeMachineGenerationContinuityError.localStoreIdentityMismatch
        }
        let minimumExpected = persistedState.committedGeneration
        guard minimumExpected > 0 else { return }
        guard let remoteHead = remoteHistory.last else {
            throw TimeMachineGenerationContinuityError.missingRemoteGeneration(
                minimumExpected: minimumExpected
            )
        }
        let remoteGeneration = remoteHead.signedManifest.manifest.generation
        guard remoteGeneration >= minimumExpected else {
            throw TimeMachineGenerationContinuityError.remoteGenerationRollback(
                minimumExpected: minimumExpected,
                actual: remoteGeneration
            )
        }
        guard let expectedDigest = persistedState.committedManifestDigest else {
            // State written by an older Delta build has only a generation
            // floor. A successful authenticated check upgrades it to the exact
            // current manifest digest.
            return
        }
        guard let committedHead = remoteHistory.first(where: {
            $0.signedManifest.manifest.generation == minimumExpected
        }) else {
            throw TimeMachineGenerationContinuityError.committedManifestNotRetained(
                generation: minimumExpected
            )
        }
        guard committedHead.signedManifest.manifestDigest == expectedDigest else {
            throw TimeMachineGenerationContinuityError.remoteManifestMismatch(
                generation: minimumExpected
            )
        }
    }
}

public enum TimeMachineSystemStateReconciliationPolicy {
    public static func reconcile(
        _ persisted: TimeMachineDestinationState,
        settings: TimeMachineRepositorySettings,
        observation: TimeMachineSystemDiskObservation,
        now: Date
    ) -> TimeMachineDestinationState {
        var resolved = persisted
        if let connected = observation.connectedResult(
            expectedDestinationIdentifier: persisted.timeMachineDestinationID
        ) {
            resolved.lifecycle = .mounted
            resolved.mountPoint = connected.timeMachineMountPoint
            resolved.diskImagePath = TimeMachineRuntimePaths
                .diskImageRelativePath(settings: settings)
            resolved.deviceIdentifier = connected.deviceIdentifier
            resolved.timeMachineDestinationID = connected.timeMachineDestinationID
            if persisted.lifecycle == .disconnecting {
                resolved.lastError = TimeMachineDestinationManagerError
                    .disconnectionInterrupted.localizedDescription
                resolved.lastFailureContext = .systemDisconnection
            } else if isSystemFailure(persisted.lastFailureContext) {
                resolved.lastError = nil
                resolved.lastFailureContext = nil
            }
            return timestampIfChanged(resolved, from: persisted, now: now)
        }

        let expectedIdentifier = persisted.timeMachineDestinationID.flatMap {
            UUID(uuidString: $0)?.uuidString
        }
        let knownDestinationRemains = expectedIdentifier.map {
            observation.knownDestinationIdentifiers.contains($0)
        } ?? false

        if observation.isCompletelyAbsent {
            resolved.mountSessionID = nil
            resolved.mountPoint = nil
            resolved.deviceIdentifier = nil
            if knownDestinationRemains {
                // A detached Time Machine disk normally remains registered
                // with macOS, just like an unplugged external disk. Preserve
                // that stable identifier so reconnect can reuse a non-empty
                // backup volume instead of attempting first-use registration.
                switch persisted.lifecycle {
                case .disconnecting, .disconnected:
                    resolved.lifecycle = .disconnected
                    resolved.lastError = nil
                    resolved.lastFailureContext = nil
                case .preparing, .mounted:
                    resolved.lifecycle = .failed
                    resolved.lastError = TimeMachineDestinationManagerError
                        .systemDiskNoLongerConnected.localizedDescription
                    resolved.lastFailureContext = .systemConnection
                default:
                    break
                }
            } else {
                resolved.timeMachineDestinationID = nil
                switch persisted.lifecycle {
                case .disconnecting:
                    resolved.lifecycle = .disconnected
                    resolved.lastError = nil
                    resolved.lastFailureContext = nil
                case .preparing, .mounted:
                    resolved.lifecycle = .failed
                    resolved.lastError = TimeMachineDestinationManagerError
                        .systemDiskNoLongerConnected.localizedDescription
                    resolved.lastFailureContext = .systemConnection
                default:
                    break
                }
            }
            return timestampIfChanged(resolved, from: persisted, now: now)
        }

        // Any observed FSKit mount or DiskImages attachment must retain the
        // cleanup-only mounted lifecycle. Unknown observation also resolves
        // here: failure to inspect is never evidence of either connection or
        // disconnection.
        resolved.lifecycle = .mounted
        if let mountPoint = observation.timeMachineMountPoint {
            resolved.mountPoint = mountPoint
        }
        if let deviceIdentifier = observation.deviceIdentifier {
            resolved.deviceIdentifier = deviceIdentifier
        }
        resolved.lastError = TimeMachineDestinationManagerError
            .systemStateCannotBeVerified.localizedDescription
        resolved.lastFailureContext = .systemDisconnection
        return timestampIfChanged(resolved, from: persisted, now: now)
    }

    private static func isSystemFailure(
        _ context: TimeMachineDestinationFailureContext?
    ) -> Bool {
        switch context {
        case .systemConnection, .systemDisconnection,
             .systemStatePersistence, .systemDestinationCleanup:
            true
        case .remotePreparation, .remoteVerification, .remoteAvailability,
             .remoteSynchronization, .storageService, nil:
            false
        }
    }

    private static func timestampIfChanged(
        _ candidate: TimeMachineDestinationState,
        from persisted: TimeMachineDestinationState,
        now: Date
    ) -> TimeMachineDestinationState {
        guard candidate != persisted else { return persisted }
        var changed = candidate
        changed.updatedAt = now
        return changed
    }
}

public struct TimeMachineObjectTransportFactory: Sendable {
    public var credentialResolver: RepositoryCredentialResolver
    public var rcloneExecutableURL: URL

    public init(
        credentialResolver: RepositoryCredentialResolver = RepositoryCredentialResolver(),
        rcloneExecutableURL: URL = RcloneExecutableLocator().locate()
    ) {
        self.credentialResolver = credentialResolver
        self.rcloneExecutableURL = rcloneExecutableURL
    }

    public func make(
        for repository: BackupRepository,
        localRootPolicy: TimeMachineLocalRootPolicy = .requireExisting
    ) throws -> AnyTimeMachineRemoteObjectTransport {
        switch repository.backend {
        case let .local(path):
            return AnyTimeMachineRemoteObjectTransport(
                LocalTimeMachineObjectTransport(
                    rootURL: URL(fileURLWithPath: path, isDirectory: true),
                    rootPolicy: localRootPolicy
                )
            )
        default:
            let builder = TimeMachineRcloneConfigurationBuilder(
                rcloneExecutableURL: rcloneExecutableURL,
                credentialResolver: credentialResolver
            )
            return AnyTimeMachineRemoteObjectTransport(
                TimeMachineRcloneObjectTransport(configuration: try builder.configuration(for: repository))
            )
        }
    }
}

public struct TimeMachineDestinationRecoveryResult: Equatable, Sendable {
    public var settings: TimeMachineRepositorySettings
    public var manifestKey: Data
    public var committedGeneration: UInt64?
    public var committedManifestDigest: String?

    public init(
        settings: TimeMachineRepositorySettings,
        manifestKey: Data,
        committedGeneration: UInt64?,
        committedManifestDigest: String?
    ) {
        self.settings = settings
        self.manifestKey = manifestKey
        self.committedGeneration = committedGeneration
        self.committedManifestDigest = committedManifestDigest
    }
}

/// Performs read-only recovery validation before Delta commits any new local
/// configuration or Keychain material.
public struct TimeMachineDestinationRecoveryInspector: Sendable {
    public var transportFactory: TimeMachineObjectTransportFactory
    public var repositoryValidator: BackupRepositoryValidator

    public init(
        transportFactory: TimeMachineObjectTransportFactory = TimeMachineObjectTransportFactory(),
        repositoryValidator: BackupRepositoryValidator = BackupRepositoryValidator()
    ) {
        self.transportFactory = transportFactory
        self.repositoryValidator = repositoryValidator
    }

    public func discoverBootstrap(
        for provisionalRepository: BackupRepository
    ) throws -> TimeMachineStoreBootstrap {
        guard provisionalRepository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        return try TimeMachineStoreBootstrapStore(
            transport: try transportFactory.make(for: provisionalRepository)
        ).discover()
    }

    public func recover(
        _ provisionalRepository: BackupRepository,
        password: String,
        cacheLimitBytes: Int64
    ) throws -> TimeMachineDestinationRecoveryResult {
        guard provisionalRepository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        let transport = try transportFactory.make(for: provisionalRepository)
        let recovered = try TimeMachineStoreBootstrapStore(transport: transport)
            .recover(password: password)
        let recoveredSettings = try recovered.bootstrap.recoveredSettings(
            cacheLimitBytes: cacheLimitBytes
        )
        let validated = try repositoryValidator.validate(
            name: provisionalRepository.name,
            backend: provisionalRepository.backend,
            format: .timeMachine,
            timeMachineSettings: recoveredSettings
        )
        guard let settings = validated.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        let store = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: recovered.manifestKey,
            transport: transport
        )
        let head = try store.loadValidatedManifestHistory().last
        if let head {
            _ = try store.loadFiles(from: head)
        }
        return TimeMachineDestinationRecoveryResult(
            settings: settings,
            manifestKey: recovered.manifestKey,
            committedGeneration: head?.signedManifest.manifest.generation,
            committedManifestDigest: head?.signedManifest.manifestDigest
        )
    }
}

public struct TimeMachineDestinationManager: Sendable {
    public var database: DeltaDatabase
    public var secretStore: KeychainSecretStore
    public var credentialResolver: RepositoryCredentialResolver
    public var lockManager: any RepositoryLocking
    public var systemOperationLockManager: any RepositoryLocking
    public var rcloneExecutableURL: URL
    public var userDiskController: any TimeMachineUserDiskControlling

    public init(
        database: DeltaDatabase,
        secretStore: KeychainSecretStore = KeychainSecretStore(),
        credentialResolver: RepositoryCredentialResolver = RepositoryCredentialResolver(),
        lockManager: any RepositoryLocking = RepositoryJobLockManager(),
        systemOperationLockManager: any RepositoryLocking = TimeMachineSystemOperationLockManager(),
        rcloneExecutableURL: URL = RcloneExecutableLocator().locate(),
        userDiskController: any TimeMachineUserDiskControlling = TimeMachineUserDiskController()
    ) {
        self.database = database
        self.secretStore = secretStore
        self.credentialResolver = credentialResolver
        self.lockManager = lockManager
        self.systemOperationLockManager = systemOperationLockManager
        self.rcloneExecutableURL = rcloneExecutableURL
        self.userDiskController = userDiskController
    }

    /// Reconciles system operations whose owning Delta process disappeared. A
    /// released operation lock proves the app/agent owner is gone. The public
    /// FSKit, DiskImages/APFS, and tmutil observations then determine whether
    /// the exact system stack is connected, absent, or only partially present.
    @discardableResult
    public func recoverInterruptedSystemOperations(
        now: Date = Date()
    ) throws -> [TimeMachineDestinationState] {
        let candidates = try database.fetchTimeMachineDestinationStates()
            .filter { $0.lifecycle == .preparing || $0.lifecycle == .disconnecting }
        guard !candidates.isEmpty else {
            return []
        }
        let repositories = Dictionary(
            uniqueKeysWithValues: try database.fetchRepositories().map { ($0.id, $0) }
        )
        var recoveredStates: [TimeMachineDestinationState] = []

        for candidate in candidates {
            guard let localLock = try systemOperationLockManager.acquire(
                repositoryID: candidate.repositoryID
            ) else {
                continue
            }
            guard
                let repository = repositories[candidate.repositoryID],
                let settings = repository.timeMachineSettings,
                repository.format == .timeMachine,
                settings.storeID == candidate.storeID
            else {
                continue
            }
            let repositoryName = repository.name
            let isDisconnect = candidate.lifecycle == .disconnecting
            let observationResult = observeSystemDisk(
                repositoryID: candidate.repositoryID,
                mountSessionID: candidate.mountSessionID,
                settings: settings
            )
            let resolvedState = TimeMachineSystemStateReconciliationPolicy
                .reconcile(
                    candidate,
                    settings: settings,
                    observation: observationResult.observation,
                    now: now
                )
            let interruptionMessage: String
            let eventMessage: String
            if resolvedState.lifecycle == .mounted {
                interruptionMessage = isDisconnect
                    ? "The Time Machine disconnection was interrupted because Delta stopped before macOS cleanup completed. The disk remains present; disconnect it again to finish safely."
                    : "The Time Machine connection was interrupted, but macOS still has the disk present. Disconnect it before changing this destination."
                eventMessage = isDisconnect
                    ? "Time Machine disconnection for '\(repositoryName)' was interrupted after Delta restarted. Disconnect must be retried."
                    : "Time Machine connection for '\(repositoryName)' was interrupted after Delta restarted. The remaining system disk requires a safe disconnect."
            } else if resolvedState.lastFailureContext == .systemDestinationCleanup {
                interruptionMessage = "Delta stopped before Time Machine destination cleanup completed. Reconnect this disk so Delta can safely match and remove the saved destination."
                eventMessage = "Time Machine system cleanup for '\(repositoryName)' requires the exact disk to be reconnected."
            } else if isDisconnect {
                interruptionMessage = "Delta stopped during disconnection; macOS now confirms that this disk and its saved destination are no longer present."
                eventMessage = "Time Machine disconnection for '\(repositoryName)' was reconciled as disconnected after Delta restarted."
            } else {
                interruptionMessage = "Delta stopped during connection; macOS now confirms that the disk is not connected. Connect it again when ready."
                eventMessage = "Time Machine connection for '\(repositoryName)' was interrupted and no system disk remains."
            }
            let recordedEventMessage = observationResult.errorDescription.map {
                "\(eventMessage) System observation failed: \($0)"
            } ?? eventMessage
            let recovery = try withExtendedLifetime(localLock) {
                try database.recoverInterruptedTimeMachineSystemOperation(
                    repositoryID: candidate.repositoryID,
                    expectedStoreID: candidate.storeID,
                    expectedLifecycle: candidate.lifecycle,
                    now: now,
                    resolvedState: resolvedState,
                    interruptionMessage: interruptionMessage,
                    eventMessage: recordedEventMessage
                )
            }
            if let recovery {
                recoveredStates.append(recovery.state)
            }
        }

        if !recoveredStates.isEmpty {
            requestServiceReload()
        }
        return recoveredStates
    }

    /// Revalidates durable `.mounted` rows against macOS. This is deliberately
    /// separate from the frequent SQLite reload loop because hdiutil and tmutil
    /// are system observations; the app invokes it at launch and on its bounded
    /// system-state cadence.
    @discardableResult
    public func reconcileMountedSystemStates(
        now: Date = Date()
    ) throws -> [TimeMachineDestinationState] {
        let repositories = Dictionary(
            uniqueKeysWithValues: try database.fetchRepositories().map { ($0.id, $0) }
        )
        let candidates = try database.fetchTimeMachineDestinationStates()
            .filter { $0.lifecycle == .mounted }
        var changedStates: [TimeMachineDestinationState] = []

        for candidate in candidates {
            guard
                let repository = repositories[candidate.repositoryID],
                let settings = repository.timeMachineSettings,
                repository.format == .timeMachine,
                settings.storeID == candidate.storeID,
                let localLock = try systemOperationLockManager.acquire(
                    repositoryID: candidate.repositoryID
                )
            else {
                continue
            }
            let observationResult = observeSystemDisk(
                repositoryID: candidate.repositoryID,
                mountSessionID: candidate.mountSessionID,
                settings: settings
            )
            let resolved = TimeMachineSystemStateReconciliationPolicy.reconcile(
                candidate,
                settings: settings,
                observation: observationResult.observation,
                now: now
            )
            guard resolved != candidate else { continue }
            try withExtendedLifetime(localLock) {
                try database.saveTimeMachineDestinationState(resolved)
                try database.appendEvent(
                    EventLog(
                        level: resolved.lifecycle == .disconnected ? .info : .warning,
                        message: observationResult.errorDescription.map {
                            "Time Machine system state for '\(repository.name)' could not be fully observed: \($0)"
                        } ?? "Time Machine system state for '\(repository.name)' was reconciled with macOS."
                    )
                )
            }
            changedStates.append(resolved)
        }

        if !changedStates.isEmpty {
            requestServiceReload()
        }
        return changedStates
    }

    private func observeSystemDisk(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) -> (
        observation: TimeMachineSystemDiskObservation,
        errorDescription: String?
    ) {
        do {
            return (
                try userDiskController.observe(
                    repositoryID: repositoryID,
                    mountSessionID: mountSessionID,
                    settings: settings
                ),
                nil
            )
        } catch {
            return (
                .unknown,
                SensitiveLogRedactor.redact(error.localizedDescription)
            )
        }
    }

    @discardableResult
    public func prepareRemoteStore(_ repository: BackupRepository) throws -> JobRun {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        try requireDisconnectedDisk(repositoryID: repository.id)
        guard let localLock = try lockManager.acquire(repositoryID: repository.id) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        defer { withExtendedLifetime(localLock) {} }

        var job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            message: "Verifying remote Time Machine storage."
        )
        try database.saveJobRun(job)
        record(
            job: job,
            repositoryID: repository.id,
            stream: .standardOutput,
            message: "Preparing an authenticated, immutable Time Machine object namespace."
        )

        do {
            let authenticationKey = try manifestAuthenticationKey(for: settings)
            let persistedState = try database.fetchTimeMachineDestinationState(
                repositoryID: repository.id
            )
            let localRootPolicy: TimeMachineLocalRootPolicy =
                (persistedState?.committedGeneration ?? 0) > 0
                ? .requireExisting
                : .createIfNeeded
            let transport = try transportFactory.make(
                for: repository,
                localRootPolicy: localRootPolicy
            )
            let store = try TimeMachineGenerationStore(
                namespace: settings.remoteNamespace,
                storeID: settings.storeID,
                authenticationKey: authenticationKey,
                transport: transport
            )
            let authenticatedHistory = try store.loadValidatedManifestHistory()
            let existingHead = authenticatedHistory.last
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: authenticatedHistory,
                persistedState: persistedState,
                expectedStoreID: settings.storeID
            )
            if let existingHead {
                _ = try store.loadFiles(from: existingHead)
            }

            let diskPassword = try secretStore.load(
                account: repository.keychainAccount,
                authenticationPolicy: .allowUserInteraction
            )
            _ = try TimeMachineStoreBootstrapStore(transport: transport).prepare(
                settings: settings,
                password: diskPassword,
                manifestKey: authenticationKey
            )

            let head: TimeMachineGenerationHead
            if let existing = existingHead {
                let refreshedHistory = try store.loadValidatedManifestHistory()
                try TimeMachineGenerationContinuityPolicy.validate(
                    remoteHistory: refreshedHistory,
                    persistedState: persistedState,
                    expectedStoreID: settings.storeID
                )
                guard let refreshedHead = refreshedHistory.last else {
                    throw TimeMachineObjectStoreError.objectNotFound(
                        "\(settings.remoteNamespace)/manifests"
                    )
                }
                if refreshedHead.signedManifest.manifestDigest
                    != existing.signedManifest.manifestDigest {
                    _ = try store.loadFiles(from: refreshedHead)
                }
                head = refreshedHead
                record(
                    job: job,
                    repositoryID: repository.id,
                    stream: .standardOutput,
                    message: "Verified committed remote generation \(refreshedHead.signedManifest.manifest.generation)."
                )
            } else {
                let writerID = UUID()
                let lease = try store.acquireLease(ownerID: writerID)
                defer { try? store.releaseLease(lease) }
                let manifest = TimeMachineGenerationManifest(
                    storeID: settings.storeID,
                    generation: 1,
                    parentManifestDigest: nil,
                    writerID: writerID,
                    fileShards: []
                )
                head = try store.commit(
                    TimeMachineGenerationCommit(
                        manifest: manifest,
                        objectsByDigest: [String: TimeMachineObjectPayload]()
                    ),
                    lease: lease
                )
                record(
                    job: job,
                    repositoryID: repository.id,
                    stream: .standardOutput,
                    message: "Created and read back the first authenticated remote generation."
                )
            }

            var state = persistedState
                ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
            state.lifecycle = .waitingForPermissions
            state.committedGeneration = head.signedManifest.manifest.generation
            state.committedManifestDigest = head.signedManifest.manifestDigest
            state.lastError = nil
            state.lastFailureContext = nil
            state.updatedAt = Date()
            try database.saveTimeMachineDestinationState(state)

            job.status = .succeeded
            job.exitCode = 0
            job.finishedAt = Date()
            job.message = "Remote storage is ready. Approve Delta's Time Machine system access to connect the disk."
            try database.saveJobRun(job)
            try database.appendEvent(
                EventLog(level: .info, message: "Time Machine storage for '\(repository.name)' was prepared and verified.")
            )
            DistributedNotificationCenter.default().postNotificationName(
                TimeMachineServiceController.reloadNotificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return job
        } catch {
            var state = (try? database.fetchTimeMachineDestinationState(repositoryID: repository.id))
                ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
            state.lifecycle = .failed
            state.lastError = TimeMachineDestinationFailurePresentation.userMessage(for: error)
            state.lastFailureContext = .remotePreparation
            state.updatedAt = Date()
            try? database.saveTimeMachineDestinationState(state)

            job.status = .failed
            job.finishedAt = Date()
            job.message = "Time Machine storage could not be prepared: \(SensitiveLogRedactor.redact(error.localizedDescription))"
            try database.saveJobRun(job)
            record(
                job: job,
                repositoryID: repository.id,
                stream: .standardError,
                message: job.message ?? "Time Machine storage could not be prepared."
            )
            try? database.appendEvent(EventLog(level: .error, message: job.message ?? "Time Machine storage preparation failed."))
            throw error
        }
    }

    @discardableResult
    public func checkRemoteStore(_ repository: BackupRepository) throws -> JobRun {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        try requireDisconnectedDisk(repositoryID: repository.id)
        guard let localLock = try lockManager.acquire(repositoryID: repository.id) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        defer { withExtendedLifetime(localLock) {} }

        var job = JobRun(
            repositoryID: repository.id,
            kind: .check,
            status: .running,
            message: "Checking the authenticated Time Machine generation."
        )
        try database.saveJobRun(job)
        do {
            guard let settings = repository.timeMachineSettings else {
                throw TimeMachineDestinationManagerError.missingSettings
            }
            let store = try generationStore(for: repository)
            let persistedState = try database.fetchTimeMachineDestinationState(
                repositoryID: repository.id
            )
            let authenticatedHistory = try store.loadValidatedManifestHistory()
            guard let preflightHead = authenticatedHistory.last else {
                try TimeMachineGenerationContinuityPolicy.validate(
                    remoteHistory: authenticatedHistory,
                    persistedState: persistedState,
                    expectedStoreID: settings.storeID
                )
                throw TimeMachineObjectStoreError.objectNotFound(
                    "\(settings.remoteNamespace)/manifests"
                )
            }
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: authenticatedHistory,
                persistedState: persistedState,
                expectedStoreID: settings.storeID
            )
            _ = try store.loadFiles(from: preflightHead)

            var maintenanceLease = try store.acquireLease(
                ownerID: UUID(),
                duration: 300
            )
            defer { try? store.releaseLease(maintenanceLease) }
            let leasedHistory = try store.loadValidatedManifestHistory()
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: leasedHistory,
                persistedState: persistedState,
                expectedStoreID: settings.storeID
            )
            guard let head = leasedHistory.last else {
                throw TimeMachineObjectStoreError.objectNotFound(
                    "\(settings.remoteNamespace)/manifests"
                )
            }
            if head.signedManifest.manifestDigest
                != preflightHead.signedManifest.manifestDigest {
                _ = try store.loadFiles(from: head)
            }
            try store.pruneManifestHistory(
                keepingNewestGenerations: 256,
                expectedHead: head,
                lease: maintenanceLease
            )
            let garbageCollection = try store.garbageCollectUnreferencedBlobs(
                lease: &maintenanceLease,
                expectedHead: head,
                gracePeriod: 7 * 24 * 60 * 60
            )
            let generation = head.signedManifest.manifest.generation
            var state = persistedState
                ?? TimeMachineDestinationState(
                    repositoryID: repository.id,
                    storeID: head.signedManifest.manifest.storeID
                )
            state.committedGeneration = generation
            state.committedManifestDigest = head.signedManifest.manifestDigest
            if state.lifecycle == .failed || state.lifecycle == .disconnected {
                state.lifecycle = .ready
            }
            state.lastError = nil
            state.lastFailureContext = nil
            state.updatedAt = Date()
            try database.saveTimeMachineDestinationState(state)

            var verifiedRepository = repository
            verifiedRepository.lastVerifiedAt = Date()
            try database.saveRepository(verifiedRepository)
            job.status = .succeeded
            job.exitCode = 0
            job.finishedAt = Date()
            job.message = "Authenticated remote generation \(generation) and its sparse-file metadata. Accounted for \(garbageCollection.inspectedBlobCount) immutable objects, marked \(garbageCollection.newlyMarkedBlobCount) for delayed cleanup, and reclaimed \(garbageCollection.deletedBlobCount)."
            try database.saveJobRun(job)
            record(
                job: job,
                repositoryID: repository.id,
                stream: .standardOutput,
                message: job.message ?? "Time Machine storage verified."
            )
            return job
        } catch {
            if let settings = repository.timeMachineSettings {
                var state = (try? database.fetchTimeMachineDestinationState(repositoryID: repository.id))
                    ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
                state.lifecycle = .failed
                state.lastError = TimeMachineDestinationFailurePresentation.userMessage(for: error)
                state.lastFailureContext = TimeMachineDestinationFailurePresentation
                    .context(forRemoteVerificationError: error)
                state.updatedAt = Date()
                try? database.saveTimeMachineDestinationState(state)
            }
            job.status = .failed
            job.finishedAt = Date()
            job.message = "Time Machine storage check failed: \(SensitiveLogRedactor.redact(error.localizedDescription))"
            try database.saveJobRun(job)
            record(
                job: job,
                repositoryID: repository.id,
                stream: .standardError,
                message: job.message ?? "Time Machine storage check failed."
            )
            throw error
        }
    }

    @discardableResult
    public func connectSystemDisk(
        _ repository: BackupRepository,
        helperClient: TimeMachineSetupHelperClient = TimeMachineSetupHelperClient()
    ) throws -> JobRun {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        guard let systemOperationLock = try systemOperationLockManager.acquire(
            repositoryID: repository.id
        ) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        defer { withExtendedLifetime(systemOperationLock) {} }
        guard let localLock = try lockManager.acquire(repositoryID: repository.id) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        guard
            let existingState = try database.fetchTimeMachineDestinationState(
                repositoryID: repository.id
            ),
            existingState.allowsSystemConnection
        else {
            throw TimeMachineDestinationManagerError.destinationNotReadyForConnection
        }
        var job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            message: "Connecting the native Time Machine disk."
        )
        try database.saveJobRun(job)
        var connectedResult: TimeMachineSetupResult?
        var localDiskResult: TimeMachineSetupResult?
        var userDiskInvocationStarted = false
        var helperInvocationStarted = false
        let mountSessionID = UUID()
        do {
            var startingState = existingState
            startingState.lifecycle = .preparing
            startingState.mountSessionID = mountSessionID
            startingState.lastError = nil
            startingState.lastFailureContext = nil
            startingState.updatedAt = Date()
            try database.saveTimeMachineDestinationState(startingState)
            // The durable `.preparing` lifecycle now excludes offline work and
            // the separate system-operation lock excludes another setup call.
            // Hand normal destination-lock ownership to the storage service,
            // which must retain it for the entire mounted lifetime.
            localLock.release()
            requestServiceReload()
            try waitForStorageService(repositoryID: repository.id)

            var password = try secretStore.loadData(
                account: repository.keychainAccount,
                authenticationPolicy: .allowUserInteraction
            )
            defer { password.resetBytes(in: password.indices) }
            guard
                !password.isEmpty,
                password.count <= TimeMachineSetupExecutionPolicy.maximumPasswordBytes
            else {
                throw TimeMachineDestinationManagerError.invalidDiskPassword
            }
            userDiskInvocationStarted = true
            let localResult = try userDiskController.connect(
                repositoryID: repository.id,
                mountSessionID: mountSessionID,
                settings: settings,
                encryptionPassword: password
            )
            localDiskResult = localResult
            let request = TimeMachineSetupRequest(
                operation: .registerDestination,
                repositoryID: repository.id,
                mountSessionID: mountSessionID,
                storeID: settings.storeID,
                volumeName: settings.volumeName,
                imageCapacityBytes: settings.imageCapacityBytes,
                timeMachineDestinationID: existingState.timeMachineDestinationID
            )
            helperInvocationStarted = true
            let result = try helperClient.execute(request)
            guard
                result.fileSystemMountPoint == localResult.fileSystemMountPoint,
                result.timeMachineMountPoint == localResult.timeMachineMountPoint,
                result.deviceIdentifier == localResult.deviceIdentifier,
                result.timeMachineDestinationID != nil
            else {
                throw TimeMachineSetupClientError.invalidResponse
            }
            connectedResult = result
            var state = existingState
            state.lifecycle = .mounted
            state.mountSessionID = mountSessionID
            state.mountPoint = result.timeMachineMountPoint
            state.diskImagePath = TimeMachineRuntimePaths.diskImageRelativePath(settings: settings)
            state.deviceIdentifier = result.deviceIdentifier
            state.timeMachineDestinationID = result.timeMachineDestinationID
            state.lastError = nil
            state.lastFailureContext = nil
            state.updatedAt = Date()
            try database.saveTimeMachineDestinationState(state)

            job.status = .succeeded
            job.exitCode = 0
            job.finishedAt = Date()
            job.message = "The encrypted remote disk is connected to macOS Time Machine."
            try database.saveJobRun(job)
            record(
                job: job,
                repositoryID: repository.id,
                stream: .standardOutput,
                message: job.message ?? "Time Machine disk connected."
            )
            try? database.appendEvent(
                EventLog(level: .info, message: "Time Machine disk '\(settings.volumeName)' was connected.")
            )
            requestServiceReload()
            return job
        } catch {
            var reportedError: Error = error
            var residualState = (error as? TimeMachineSetupClientError)?.fileSystemState
                ?? (error as? TimeMachineUserDiskControllerError)?.fileSystemState
            let helperReturnedStructuredFailure: Bool = {
                guard let helperError = error as? TimeMachineSetupClientError else {
                    return false
                }
                if case .operationFailed = helperError { return true }
                return false
            }()
            if connectedResult == nil,
               localDiskResult != nil,
               (!helperInvocationStarted || helperReturnedStructuredFailure) {
                do {
                    try userDiskController.disconnect(
                        repositoryID: repository.id,
                        mountSessionID: mountSessionID,
                        settings: settings
                    )
                    localDiskResult = nil
                    residualState = .unmounted
                } catch {
                    reportedError = error
                    residualState = (error as? TimeMachineUserDiskControllerError)?.fileSystemState
                }
            }
            let storageServiceFailure: String? = {
                guard let managerError = reportedError as? TimeMachineDestinationManagerError else {
                    return nil
                }
                if case let .storageServiceUnavailable(message) = managerError {
                    return message
                }
                return nil
            }()
            var state = (try? database.fetchTimeMachineDestinationState(repositoryID: repository.id))
                ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
            if let connectedResult {
                state.lifecycle = .mounted
                state.mountPoint = connectedResult.timeMachineMountPoint
                state.diskImagePath = TimeMachineRuntimePaths.diskImageRelativePath(settings: settings)
                state.deviceIdentifier = connectedResult.deviceIdentifier
                state.timeMachineDestinationID = connectedResult.timeMachineDestinationID
                state.lastError = TimeMachineDestinationManagerError.connectedButStateNotSaved.localizedDescription
                state.lastFailureContext = .systemStatePersistence
            } else if let localDiskResult {
                state.lifecycle = .mounted
                state.mountPoint = localDiskResult.timeMachineMountPoint
                state.diskImagePath = TimeMachineRuntimePaths.diskImageRelativePath(settings: settings)
                state.deviceIdentifier = localDiskResult.deviceIdentifier
                state.lastError = TimeMachineDestinationManagerError
                    .connectionRollbackIncomplete.localizedDescription
                state.lastFailureContext = .systemConnection
            } else if let storageServiceFailure, !userDiskInvocationStarted {
                state.lifecycle = .failed
                state.lastError = SensitiveLogRedactor.redact(storageServiceFailure)
                state.lastFailureContext = .storageService
            } else if userDiskInvocationStarted, residualState != .unmounted {
                state.lifecycle = .mounted
                state.lastError = TimeMachineDestinationManagerError
                    .connectionRollbackIncomplete.localizedDescription
                state.lastFailureContext = .systemConnection
            } else {
                state.lifecycle = .failed
                state.lastError = SensitiveLogRedactor.redact(reportedError.localizedDescription)
                state.lastFailureContext = .systemConnection
            }
            if connectedResult == nil,
               localDiskResult == nil,
               (!userDiskInvocationStarted || residualState == .unmounted) {
                state.mountSessionID = nil
            }
            state.updatedAt = Date()
            try? database.saveTimeMachineDestinationState(state)
            requestServiceReload()
            job.status = .failed
            job.finishedAt = Date()
            job.message = connectedResult == nil
                ? "The Time Machine disk could not be connected: \(SensitiveLogRedactor.redact(reportedError.localizedDescription))"
                : "The Time Machine disk connected, but Delta could not save all of its connection state: \(SensitiveLogRedactor.redact(reportedError.localizedDescription))"
            try? database.saveJobRun(job)
            record(
                job: job,
                repositoryID: repository.id,
                stream: .standardError,
                message: job.message ?? "Time Machine disk connection failed."
            )
            if connectedResult != nil {
                throw TimeMachineDestinationManagerError.connectedButStateNotSaved
            }
            if userDiskInvocationStarted, residualState != .unmounted {
                throw TimeMachineDestinationManagerError.connectionRollbackIncomplete
            }
            throw reportedError
        }
    }

    @discardableResult
    public func disconnectSystemDisk(
        _ repository: BackupRepository
    ) throws -> JobRun {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        guard let systemOperationLock = try systemOperationLockManager.acquire(
            repositoryID: repository.id
        ) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        defer { withExtendedLifetime(systemOperationLock) {} }
        guard
            let state = try database.fetchTimeMachineDestinationState(repositoryID: repository.id),
            state.lifecycle == .mounted
        else {
            throw TimeMachineDestinationManagerError.destinationNotConnected
        }
        var job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            message: "Disconnecting the Time Machine disk."
        )
        try database.saveJobRun(job)
        var disconnectedSystemDisk = false
        do {
            var disconnectingState = state
            disconnectingState.lifecycle = .disconnecting
            disconnectingState.lastError = nil
            disconnectingState.lastFailureContext = nil
            disconnectingState.updatedAt = Date()
            try database.saveTimeMachineDestinationState(disconnectingState)
            requestServiceReload()

            // An ordinary disconnect is the equivalent of unplugging a Time
            // Machine disk. Keep macOS's destination registration so an
            // existing, non-empty backup volume can be attached again without
            // being misclassified as a brand-new destination.
            try userDiskController.disconnect(
                repositoryID: repository.id,
                mountSessionID: state.mountSessionID,
                settings: settings
            )
            disconnectedSystemDisk = true

            var updatedState = state
            updatedState.lifecycle = .disconnected
            updatedState.mountSessionID = nil
            updatedState.mountPoint = nil
            updatedState.deviceIdentifier = nil
            updatedState.lastError = nil
            updatedState.lastFailureContext = nil
            updatedState.updatedAt = Date()
            try database.saveTimeMachineDestinationState(updatedState)
            job.status = .succeeded
            job.exitCode = 0
            job.finishedAt = Date()
            job.message = "The Time Machine disk was disconnected safely."
            try database.saveJobRun(job)
            requestServiceReload()
            return job
        } catch {
            let residualState = (error as? TimeMachineUserDiskControllerError)?
                .fileSystemState
            var failedState = (try? database.fetchTimeMachineDestinationState(
                repositoryID: repository.id
            )) ?? state
            if disconnectedSystemDisk || residualState == .unmounted {
                failedState.lifecycle = .disconnected
                failedState.mountSessionID = nil
                failedState.mountPoint = nil
                failedState.deviceIdentifier = nil
                failedState.lastError = disconnectedSystemDisk
                    ? TimeMachineDestinationManagerError
                        .disconnectedButStateNotSaved.localizedDescription
                    : SensitiveLogRedactor.redact(error.localizedDescription)
                failedState.lastFailureContext = disconnectedSystemDisk
                    ? .systemStatePersistence
                    : .systemDisconnection
            } else {
                // A failed detach does not prove that DiskImages or FSKit is
                // gone. Preserve the cleanup-only mounted lifecycle and the
                // saved destination identity.
                failedState.lifecycle = .mounted
                failedState.lastError = SensitiveLogRedactor.redact(
                    error.localizedDescription
                )
                failedState.lastFailureContext = .systemDisconnection
            }
            failedState.updatedAt = Date()
            try? database.saveTimeMachineDestinationState(failedState)
            requestServiceReload()
            job.status = .failed
            job.finishedAt = Date()
            job.message = disconnectedSystemDisk
                ? "The Time Machine disk disconnected, but Delta could not save the updated state: \(SensitiveLogRedactor.redact(error.localizedDescription))"
                : "The Time Machine disk could not be disconnected: \(SensitiveLogRedactor.redact(error.localizedDescription))"
            try? database.saveJobRun(job)
            throw disconnectedSystemDisk
                ? TimeMachineDestinationManagerError.disconnectedButStateNotSaved
                : error
        }
    }

    /// Removes the verified mounted disk from macOS Time Machine, then
    /// detaches it. This is reserved for the explicit destructive
    /// Remove Destination workflow; ordinary Disconnect preserves the saved
    /// macOS destination so non-empty backup history remains reconnectable.
    @discardableResult
    public func removeSystemDestinationAndDisconnect(
        _ repository: BackupRepository,
        helperClient: TimeMachineSetupHelperClient = TimeMachineSetupHelperClient()
    ) throws -> JobRun {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        guard let systemOperationLock = try systemOperationLockManager.acquire(
            repositoryID: repository.id
        ) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        defer { withExtendedLifetime(systemOperationLock) {} }
        guard
            let state = try database.fetchTimeMachineDestinationState(repositoryID: repository.id),
            state.lifecycle == .mounted
        else {
            throw TimeMachineDestinationManagerError.destinationNotConnected
        }
        var job = JobRun(
            repositoryID: repository.id,
            kind: .initializeRepository,
            status: .running,
            message: "Disconnecting the Time Machine disk."
        )
        try database.saveJobRun(job)
        var disconnectedSystemDisk = false
        var destinationConfigurationRemoved = false
        var unresolvedSavedDestination = false
        do {
            var disconnectingState = state
            disconnectingState.lifecycle = .disconnecting
            disconnectingState.lastError = nil
            disconnectingState.lastFailureContext = nil
            disconnectingState.updatedAt = Date()
            try database.saveTimeMachineDestinationState(disconnectingState)
            requestServiceReload()
            let removalResult = try helperClient.execute(
                TimeMachineSetupRequest(
                    operation: .removeDestination,
                    repositoryID: repository.id,
                    mountSessionID: state.mountSessionID,
                    storeID: settings.storeID,
                    volumeName: settings.volumeName,
                    imageCapacityBytes: settings.imageCapacityBytes,
                    timeMachineDestinationID: state.timeMachineDestinationID
                )
            )
            destinationConfigurationRemoved = true
            unresolvedSavedDestination = removalResult.hasUnresolvedSavedDestination
            try userDiskController.disconnect(
                repositoryID: repository.id,
                mountSessionID: state.mountSessionID,
                settings: settings
            )
            disconnectedSystemDisk = true
            var updatedState = state
            updatedState.lifecycle = unresolvedSavedDestination ? .failed : .disconnected
            updatedState.mountSessionID = nil
            updatedState.mountPoint = nil
            updatedState.deviceIdentifier = nil
            if !unresolvedSavedDestination {
                updatedState.timeMachineDestinationID = nil
            }
            updatedState.lastError = unresolvedSavedDestination
                ? TimeMachineDestinationIdentityPolicyError
                    .destinationIdentityCannotBeVerified.localizedDescription
                : nil
            updatedState.lastFailureContext = unresolvedSavedDestination
                ? .systemDestinationCleanup
                : nil
            updatedState.updatedAt = Date()
            try database.saveTimeMachineDestinationState(updatedState)
            job.status = unresolvedSavedDestination ? .failed : .succeeded
            job.exitCode = unresolvedSavedDestination ? nil : 0
            job.finishedAt = Date()
            job.message = unresolvedSavedDestination
                ? TimeMachineDestinationIdentityPolicyError
                    .destinationIdentityCannotBeVerified.localizedDescription
                : "The Time Machine disk was disconnected safely."
            try database.saveJobRun(job)
            requestServiceReload()
            if unresolvedSavedDestination {
                throw TimeMachineDestinationIdentityPolicyError
                    .destinationIdentityCannotBeVerified
            }
            return job
        } catch {
            if disconnectedSystemDisk, unresolvedSavedDestination {
                requestServiceReload()
                throw error
            }
            let residualState = (error as? TimeMachineSetupClientError)?.fileSystemState
                ?? (error as? TimeMachineUserDiskControllerError)?.fileSystemState
            if let settings = repository.timeMachineSettings {
                var failedState = (try? database.fetchTimeMachineDestinationState(repositoryID: repository.id))
                    ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
                if disconnectedSystemDisk {
                    failedState.lifecycle = .disconnected
                    failedState.mountSessionID = nil
                    failedState.mountPoint = nil
                    failedState.deviceIdentifier = nil
                    failedState.timeMachineDestinationID = nil
                    failedState.lastError = TimeMachineDestinationManagerError
                        .disconnectedButStateNotSaved.localizedDescription
                    failedState.lastFailureContext = .systemStatePersistence
                } else if residualState == .unmounted {
                    failedState.lifecycle = .failed
                    failedState.mountSessionID = nil
                    failedState.mountPoint = nil
                    failedState.deviceIdentifier = nil
                    if destinationConfigurationRemoved {
                        failedState.timeMachineDestinationID = nil
                    }
                    failedState.lastError = SensitiveLogRedactor.redact(error.localizedDescription)
                    failedState.lastFailureContext = .systemDestinationCleanup
                } else {
                    // A failed detach does not prove that DiskImages or FSKit
                    // is gone. Preserve the mounted lifecycle and identifiers
                    // so the only safe next action remains another explicit
                    // disconnect.
                    failedState.lifecycle = .mounted
                    failedState.lastError = SensitiveLogRedactor.redact(error.localizedDescription)
                    failedState.lastFailureContext = .systemDisconnection
                }
                failedState.updatedAt = Date()
                try? database.saveTimeMachineDestinationState(failedState)
            }
            requestServiceReload()
            job.status = .failed
            job.finishedAt = Date()
            job.message = disconnectedSystemDisk
                ? "The Time Machine disk disconnected, but Delta could not save the updated state: \(SensitiveLogRedactor.redact(error.localizedDescription))"
                : "The Time Machine disk could not be disconnected: \(SensitiveLogRedactor.redact(error.localizedDescription))"
            try? database.saveJobRun(job)
            throw disconnectedSystemDisk
                ? TimeMachineDestinationManagerError.disconnectedButStateNotSaved
                : error
        }
    }

    private func waitForStorageService(
        repositoryID: UUID,
        timeout: TimeInterval = 20
    ) throws {
        let socketPath = try TimeMachineRuntimePaths.socketURL(repositoryID: repositoryID).path
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = TimeMachineDiskProtocolError.disconnected
        let peerValidator = DeltaCodeSigningPeerValidator(
            allowedIdentifiers: [TimeMachineServiceController.codeSigningIdentifier]
        )
        while Date() < deadline {
            do {
                _ = try TimeMachineDiskProtocolClient(
                    socketPath: socketPath,
                    repositoryID: repositoryID,
                    peerValidator: { peerValidator.validate(auditToken: $0) }
                ).perform(
                    TimeMachineDiskRequest(operation: .status)
                )
                return
            } catch {
                lastError = error
                if let state = try? database.fetchTimeMachineDestinationState(
                    repositoryID: repositoryID
                ),
                   state.lifecycle == .failed,
                   state.lastFailureContext == .storageService,
                   let serviceError = state.lastError,
                   !serviceError.isEmpty {
                    throw TimeMachineDestinationManagerError.storageServiceUnavailable(
                        serviceError
                    )
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError
    }

    private func requestServiceReload() {
        DistributedNotificationCenter.default().postNotificationName(
            TimeMachineServiceController.reloadNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func requireDisconnectedDisk(repositoryID: UUID) throws {
        guard let state = try database.fetchTimeMachineDestinationState(repositoryID: repositoryID) else {
            return
        }
        if state.lifecycle == .mounted
            || state.lifecycle == .preparing
            || state.lifecycle == .disconnecting {
            throw TimeMachineDestinationManagerError.requiresDisconnectedDisk
        }
    }

    private func manifestAuthenticationKey(for settings: TimeMachineRepositorySettings) throws -> Data {
        let encoded = try secretStore.load(
            account: settings.manifestKeychainAccount,
            authenticationPolicy: .failIfInteractionNeeded
        )
        guard let data = Data(base64Encoded: encoded), data.count >= 32 else {
            throw TimeMachineDestinationManagerError.invalidManifestSecret
        }
        return data
    }

    private func generationStore(
        for repository: BackupRepository
    ) throws -> TimeMachineGenerationStore {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        return try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: try manifestAuthenticationKey(for: settings),
            transport: try transportFactory.make(for: repository)
        )
    }

    private var transportFactory: TimeMachineObjectTransportFactory {
        TimeMachineObjectTransportFactory(
            credentialResolver: credentialResolver,
            rcloneExecutableURL: rcloneExecutableURL
        )
    }

    private func record(
        job: JobRun,
        repositoryID: UUID,
        stream: ResticOutputStream,
        message: String
    ) {
        try? database.appendJobLog(
            JobLogEntry(
                jobID: job.id,
                repositoryID: repositoryID,
                stream: stream,
                message: String(SensitiveLogRedactor.redact(message).prefix(4_000))
            )
        )
    }
}
