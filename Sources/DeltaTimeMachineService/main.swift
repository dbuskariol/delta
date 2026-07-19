import DeltaCore
import DeltaTimeMachineIPC
import Foundation
import OSLog

/// All mutable runtime/retry state is confined to the service's main run loop.
/// Distributed notifications don't promise to invoke selector observers on the
/// registering thread, so `reload()` explicitly hops before touching it.
private final class TimeMachineServiceCoordinator: NSObject {
    private struct Runtime {
        var repository: BackupRepository
        var activationLifecycle: TimeMachineDestinationLifecycle
        var backend: TimeMachineDiskBackend
        var server: TimeMachineDiskProtocolServer
    }

    private let logger = Logger(subsystem: "com.delta.backup", category: "TimeMachineService")
    private let database: DeltaDatabase
    private let secretStore: KeychainSecretStore
    private let transportFactory: TimeMachineObjectTransportFactory
    private let expectedFileSystemExtensionCodeHash: Data
    private var runtimes: [UUID: Runtime] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryWorkItems: [UUID: DispatchWorkItem] = [:]

    init(
        database: DeltaDatabase,
        expectedFileSystemExtensionCodeHash: Data
    ) {
        self.database = database
        self.expectedFileSystemExtensionCodeHash = expectedFileSystemExtensionCodeHash
        let secretStore = KeychainSecretStore()
        self.secretStore = secretStore
        self.transportFactory = TimeMachineObjectTransportFactory(
            credentialResolver: RepositoryCredentialResolver(
                secretStore: secretStore,
                authenticationPolicy: .failIfInteractionNeeded
            ),
            rcloneExecutableURL: RcloneExecutableLocator().locate()
        )
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reload),
            name: TimeMachineServiceController.reloadNotificationName,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        for item in retryWorkItems.values { item.cancel() }
        stopAll()
    }

    func start() {
        reload()
    }

    @objc private func reload() {
        guard Thread.isMainThread else {
            performSelector(onMainThread: #selector(reload), with: nil, waitUntilDone: false)
            return
        }
        let repositories: [BackupRepository]
        let states: [UUID: TimeMachineDestinationLifecycle]
        do {
            states = Dictionary(
                uniqueKeysWithValues: try database.fetchTimeMachineDestinationStates().map {
                    ($0.repositoryID, $0.lifecycle)
                }
            )
            repositories = try database.fetchRepositories().filter { repository in
                guard repository.format == .timeMachine else { return false }
                return states[repository.id] == .preparing
                    || states[repository.id] == .disconnecting
                    || states[repository.id] == .mounted
            }
        } catch {
            logger.error(
                "Could not read Time Machine destinations: \(SensitiveLogRedactor.redact(error.localizedDescription), privacy: .public)"
            )
            return
        }


        let desiredIDs = Set(repositories.map(\.id))
        for repositoryID in runtimes.keys.filter({ !desiredIDs.contains($0) }) {
            runtimes[repositoryID]?.server.stop()
            runtimes.removeValue(forKey: repositoryID)
        }
        for repositoryID in retryWorkItems.keys.filter({ !desiredIDs.contains($0) }) {
            cancelRetry(repositoryID: repositoryID)
        }

        for repository in repositories {
            let activationLifecycle = states[repository.id] ?? .failed
            if var existing = runtimes[repository.id], existing.repository == repository {
                existing.activationLifecycle = activationLifecycle
                runtimes[repository.id] = existing
                continue
            }
            if let existing = runtimes.removeValue(forKey: repository.id) {
                existing.server.stop()
            }
            do {
                guard let settings = repository.timeMachineSettings else {
                    throw TimeMachineDestinationManagerError.missingSettings
                }
                let encodedKey = try secretStore.load(
                    account: settings.manifestKeychainAccount,
                    authenticationPolicy: .failIfInteractionNeeded
                )
                guard let authenticationKey = Data(base64Encoded: encodedKey), authenticationKey.count >= 32 else {
                    throw TimeMachineDestinationManagerError.invalidManifestSecret
                }
                let backend = try TimeMachineDiskBackend(
                    repository: repository,
                    database: database,
                    authenticationKey: authenticationKey,
                    transport: try transportFactory.make(for: repository)
                )
                let peerValidator = DeltaCodeSigningPeerValidator(
                    allowedIdentifiers: [
                        "com.delta.backup",
                        TimeMachineFileSystemExtensionProbe.bundleIdentifier
                    ],
                    expectedCodeHashesByIdentifier: [
                        TimeMachineFileSystemExtensionProbe.bundleIdentifier:
                            expectedFileSystemExtensionCodeHash
                    ]
                )
                let peerLogger = logger
                let server = TimeMachineDiskProtocolServer(
                    socketPath: backend.socketPath,
                    peerValidator: {
                        let isTrusted = peerValidator.validate(auditToken: $0)
                        if !isTrusted {
                            peerLogger.error(
                                "Rejected an unauthenticated Time Machine disk client."
                            )
                        }
                        return isTrusted
                    }
                ) {
                    guard $0.repositoryID == repository.id else {
                        return TimeMachineDiskProtocolResult(
                            response: TimeMachineDiskResponse(
                                repositoryID: repository.id,
                                errorNumber: EPERM,
                                message: "The request belongs to a different Time Machine destination."
                            )
                        )
                    }
                    return backend.handle(request: $0, payload: $1)
                }
                try server.start()
                runtimes[repository.id] = Runtime(
                    repository: repository,
                    activationLifecycle: activationLifecycle,
                    backend: backend,
                    server: server
                )
                cancelRetry(repositoryID: repository.id)
                logger.info("Time Machine storage service is ready for destination \(repository.id.uuidString, privacy: .public)")
            } catch {
                logger.error(
                    "Could not start Time Machine destination \(repository.id.uuidString, privacy: .public): \(SensitiveLogRedactor.redact(error.localizedDescription), privacy: .public)"
                )
                if let settings = repository.timeMachineSettings {
                    var state = (try? database.fetchTimeMachineDestinationState(repositoryID: repository.id))
                        ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
                    let requiresLiveBackend = activationLifecycle == .mounted
                        || activationLifecycle == .disconnecting
                    state.lifecycle = requiresLiveBackend ? activationLifecycle : .failed
                    state.lastError = SensitiveLogRedactor.redact(error.localizedDescription)
                    state.lastFailureContext = .storageService
                    state.updatedAt = Date()
                    try? database.saveTimeMachineDestinationState(state)
                }
                if activationLifecycle == .mounted || activationLifecycle == .disconnecting {
                    scheduleRetry(repositoryID: repository.id)
                }
            }
        }
    }

    private func scheduleRetry(repositoryID: UUID) {
        guard retryWorkItems[repositoryID] == nil else { return }
        let attempt = retryAttempts[repositoryID, default: 0]
        let delay = min(pow(2, Double(attempt + 1)), 60)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItems.removeValue(forKey: repositoryID)
            self.reload()
        }
        retryAttempts[repositoryID] = min(attempt + 1, 30)
        retryWorkItems[repositoryID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        logger.info("Will retry Time Machine destination \(repositoryID.uuidString, privacy: .public) in \(delay, privacy: .public) seconds")
    }

    private func cancelRetry(repositoryID: UUID) {
        retryWorkItems.removeValue(forKey: repositoryID)?.cancel()
        retryAttempts.removeValue(forKey: repositoryID)
    }

    private func stopAll() {
        for runtime in runtimes.values {
            runtime.server.stop()
        }
        runtimes.removeAll()
    }
}

do {
    let coordinator = TimeMachineServiceCoordinator(
        database: try DeltaDatabase.live(),
        expectedFileSystemExtensionCodeHash: try TimeMachineInstalledComponentLayout
            .currentFileSystemExtensionCodeHash()
    )
    coordinator.start()
    RunLoop.main.run()
} catch {
    let message = SensitiveLogRedactor.redact(error.localizedDescription)
    FileHandle.standardError.write(Data("DeltaTimeMachineService failed: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
