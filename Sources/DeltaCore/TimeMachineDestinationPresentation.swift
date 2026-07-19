import Foundation

public enum TimeMachineDestinationPrimaryAction: Equatable, Sendable {
    case connect
    case repair
    case checkRemoteStorage
    case backUpNow
    case none
}

/// Converts typed storage failures into concise product guidance while jobs
/// and Activity retain the exact redacted technical error as audit evidence.
public enum TimeMachineDestinationFailurePresentation {
    public static func context(
        forRemoteVerificationError error: Error
    ) -> TimeMachineDestinationFailureContext {
        if let storageError = error as? TimeMachineObjectStoreError,
           storageError == .localDestinationUnavailable {
            return .remoteAvailability
        }
        if error is TimeMachineBinaryProcessError {
            return .remoteAvailability
        }
        if let rcloneError = error as? TimeMachineRcloneError,
           case .commandFailed = rcloneError {
            return .remoteAvailability
        }
        return .remoteVerification
    }

    public static func userMessage(for error: Error) -> String {
        if error is TimeMachineBinaryProcessError {
            return "Remote Time Machine storage did not respond in time. Check the provider connection, then try again."
        }
        if let rcloneError = error as? TimeMachineRcloneError,
           case .commandFailed = rcloneError {
            return "Remote Time Machine storage is unavailable or access was rejected. Check the provider connection and credentials, then try again."
        }
        guard let storageError = error as? TimeMachineObjectStoreError else {
            return SensitiveLogRedactor.redact(error.localizedDescription)
        }
        switch storageError {
        case .localDestinationUnavailable:
            return "The local or mounted Time Machine destination is unavailable. Reconnect the drive or server, restore access, then check it again."
        case .objectNotFound:
            return "Remote Time Machine data is incomplete. Restore the missing data from your storage provider or a known-good copy, then check the destination again."
        case .invalidObjectDigest:
            return "Remote Time Machine data failed integrity verification. Restore a known-good provider version, then check the destination again."
        case .invalidManifest, .invalidManifestAuthentication,
             .invalidParentManifest, .manifestForkDetected:
            return "Remote Time Machine history failed authentication or integrity verification. Restore a known-good provider version, then check the destination again."
        case .invalidObjectPath, .objectAlreadyExists:
            return "Remote Time Machine storage has an invalid object layout. Check the destination again after restoring a known-good provider version."
        default:
            return SensitiveLogRedactor.redact(storageError.localizedDescription)
        }
    }
}

public enum DeltaSoftwareUpdateReadiness: Equatable, Sendable {
    case ready
    case applicationStateUnavailable
    case operationInProgress
    case timeMachineDestinationsConnected(Set<UUID>)

    public var allowsUpdate: Bool {
        self == .ready
    }
}

/// A Sparkle install replaces the app bundle that owns the Time Machine
/// service and FSKit extension. Update checks and installation therefore wait
/// until every system disk is authoritatively disconnected. Fixed-path remote
/// setup and cleanup-only destination identifiers do not require a live
/// extension and do not block an update.
public struct TimeMachineSoftwareUpdatePolicy: Sendable {
    public init() {}

    public func readiness(
        states: [UUID: TimeMachineDestinationState],
        stateIsAuthoritative: Bool
    ) -> DeltaSoftwareUpdateReadiness {
        guard stateIsAuthoritative else {
            return .applicationStateUnavailable
        }
        let connected = Set(states.values.compactMap { state -> UUID? in
            let activeLifecycle = state.lifecycle == .preparing
                || state.lifecycle == .mounted
                || state.lifecycle == .disconnecting
            let residualSystemDisk = state.mountPoint != nil || state.deviceIdentifier != nil
            return activeLifecycle || residualSystemDisk ? state.repositoryID : nil
        })
        return connected.isEmpty ? .ready : .timeMachineDestinationsConnected(connected)
    }
}

/// One presentation contract for every Time Machine destination surface.
/// The persisted lifecycle remains authoritative; a failure context only
/// selects the truthful recovery action and wording for that lifecycle.
public struct TimeMachineDestinationPresentation: Equatable, Sendable {
    public var status: String
    public var primaryAction: TimeMachineDestinationPrimaryAction
    public var warningTitle: String?
    public var warningMessage: String?
    public var warningSymbol: String?
    public var isMounted: Bool

    public init(
        status: String,
        primaryAction: TimeMachineDestinationPrimaryAction,
        warningTitle: String?,
        warningMessage: String?,
        warningSymbol: String?,
        isMounted: Bool
    ) {
        self.status = status
        self.primaryAction = primaryAction
        self.warningTitle = warningTitle
        self.warningMessage = warningMessage
        self.warningSymbol = warningSymbol
        self.isMounted = isMounted
    }

    public static func make(
        state: TimeMachineDestinationState?
    ) -> TimeMachineDestinationPresentation {
        guard let state else {
            return TimeMachineDestinationPresentation(
                status: "Not Configured",
                primaryAction: .repair,
                warningTitle: "Time Machine disk setup is incomplete",
                warningMessage: "Delta's local state for this Time Machine disk is missing. Repair its setup before connecting.",
                warningSymbol: "wrench.and.screwdriver",
                isMounted: false
            )
        }

        let primaryAction: TimeMachineDestinationPrimaryAction
        switch state.lifecycle {
        case .waitingForPermissions, .ready, .disconnected:
            primaryAction = .connect
        case .preparing, .disconnecting:
            primaryAction = .none
        case .mounted:
            primaryAction = state.lastError == nil ? .backUpNow : .none
        case .needsRepair:
            primaryAction = .repair
        case .failed:
            if state.lastFailureContext == .remoteVerification
                || state.lastFailureContext == .remoteAvailability {
                primaryAction = .checkRemoteStorage
            } else {
                primaryAction = state.allowsSystemConnection ? .connect : .repair
            }
        }

        return TimeMachineDestinationPresentation(
            status: status(for: state),
            primaryAction: primaryAction,
            warningTitle: state.lastError.map { _ in warningTitle(for: state) },
            warningMessage: state.lastError.map(
                TimeMachineSetupCommandFailurePolicy.normalizedUserMessage
            ),
            warningSymbol: state.lastError.map { _ in warningSymbol(for: state) },
            isMounted: state.lifecycle == .mounted || state.lifecycle == .disconnecting
        )
    }

    private static func status(for state: TimeMachineDestinationState) -> String {
        guard state.lastError != nil else {
            return state.lifecycle.displayName
        }
        switch state.lastFailureContext {
        case .systemConnection:
            return state.lifecycle == .mounted ? "Disconnect Required" : "Connection Failed"
        case .systemDisconnection:
            return "Disconnect Failed"
        case .systemStatePersistence:
            return state.lifecycle == .mounted ? "Connected — Needs Attention" : "Needs Attention"
        case .systemDestinationCleanup:
            return "Cleanup Needed"
        case .remoteSynchronization, .storageService:
            return state.lifecycle == .mounted ? "Reconnecting" : state.lifecycle.displayName
        case .remotePreparation:
            return "Needs Repair"
        case .remoteVerification:
            return "Verification Failed"
        case .remoteAvailability:
            return "Storage Unavailable"
        case nil:
            return state.lifecycle == .mounted ? "Needs Attention" : state.lifecycle.displayName
        }
    }

    private static func warningTitle(for state: TimeMachineDestinationState) -> String {
        switch state.lastFailureContext {
        case .remotePreparation:
            return "Time Machine disk setup needs repair"
        case .remoteVerification:
            return "Time Machine verification failed"
        case .remoteAvailability:
            return "Time Machine storage is unavailable"
        case .systemConnection:
            return state.lifecycle == .mounted
                ? "Time Machine connection cleanup is incomplete"
                : "Time Machine disk could not connect"
        case .systemDisconnection:
            return "Time Machine disk is still connected"
        case .systemStatePersistence:
            return "Time Machine disk state was not saved"
        case .systemDestinationCleanup:
            return "Remove the old Time Machine destination"
        case .remoteSynchronization, .storageService:
            return state.lifecycle == .mounted
                ? "Time Machine disk is reconnecting"
                : "Time Machine storage is unavailable"
        case nil:
            return state.lifecycle == .needsRepair || state.lifecycle == .failed
                ? "Time Machine disk needs repair"
                : "Time Machine disk is unavailable"
        }
    }

    private static func warningSymbol(for state: TimeMachineDestinationState) -> String {
        switch state.lastFailureContext {
        case .remotePreparation:
            return "wrench.and.screwdriver"
        case .remoteVerification:
            return "checkmark.shield"
        case .remoteAvailability:
            return "externaldrive.badge.xmark"
        case .systemConnection:
            return state.lifecycle == .mounted ? "eject.fill" : "externaldrive.badge.xmark"
        case .systemDisconnection:
            return "eject.fill"
        case .systemStatePersistence:
            return "exclamationmark.triangle"
        case .systemDestinationCleanup:
            return "arrow.triangle.2.circlepath"
        case .remoteSynchronization, .storageService:
            return "arrow.triangle.2.circlepath"
        case nil:
            return "exclamationmark.triangle"
        }
    }
}
