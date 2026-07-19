import DeltaTimeMachineIPC
import Foundation

public enum DeltaCodeSigningRequirement {
    public static let teamIdentifier = DeltaTimeMachineIPCIdentity.teamIdentifier

    public static func designated(identifier: String) -> String {
        DeltaTimeMachineIPCIdentity.designatedRequirement(identifier: identifier)
    }
}

/// One connection may invoke several bounded user-session and privileged system
/// tools. These limits are shared so Delta never reports a timeout while an
/// earlier mutation can still be running.
public enum TimeMachineSetupExecutionPolicy {
    public static let operationRuntime: TimeInterval = 10 * 60
    public static let rollbackRuntime: TimeInterval = 60
    public static let clientReplyTimeout: TimeInterval = 12 * 60
    public static let helperReadinessTimeout: TimeInterval = 15
    public static let maximumRequestBytes = 65_536
    public static let maximumPasswordBytes = TimeMachineRepositorySettings
        .maximumDiskPasswordBytes
}

/// `tmutil` describes its caller as Terminal even when it was launched by a
/// signed app helper. Normalize only the exact public Time Machine command and
/// FDA diagnostic so Delta can direct the user to Delta's own permission row.
public enum TimeMachineSetupCommandFailurePolicy {
    public static let fullDiskAccessUserMessage =
        "Full Disk Access is required to add or remove this disk in Time Machine. Open Delta Settings, choose Permissions, allow Delta in macOS Full Disk Access, then try again."

    public static func requiresFullDiskAccess(
        executablePath: String,
        standardError: String
    ) -> Bool {
        executablePath == "/usr/bin/tmutil"
            && standardError.localizedCaseInsensitiveContains(
                "requires Full Disk Access"
            )
    }

    public static func normalizedUserMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("tmutil"),
           message.localizedCaseInsensitiveContains("requires Full Disk Access") {
            return fullDiskAccessUserMessage
        }
        return message
    }
}

/// The BSD mount tool requires `-F` to route a custom file-system type through
/// FSKit. Without it, `mount` falls back to the legacy `/Library/Filesystems`
/// plug-in convention and never reaches Delta's enabled FSKit module.
public enum TimeMachineFSKitMountCommand {
    public static let executable = "/sbin/mount"

    public static func arguments(sourcePath: String, mountPoint: String) -> [String] {
        // FSKit constructs FSPathURLResource access from these mount flags.
        // State read/write intent explicitly so the sandbox extension carries
        // writable access, and refuse to follow a substituted mount-point
        // symlink between Delta's validation and mount(8).
        ["-F", "-k", "-w", "-t", "delta-tm", sourcePath, mountPoint]
    }
}

/// FSKit reports path resources as either an ordinary absolute path or a file
/// URL depending on the dispatch path. Normalize both forms before a privileged
/// caller trusts the mounted resource identity.
public enum TimeMachineMountedFileSystemIdentity {
    public static func matches(
        reportedSource: String,
        expectedSourceURL: URL
    ) -> Bool {
        guard !reportedSource.utf8.contains(0) else { return false }
        let reportedURL: URL
        if reportedSource.hasPrefix("file://"),
           let parsed = URL(string: reportedSource),
           parsed.isFileURL {
            reportedURL = parsed
        } else {
            guard reportedSource.hasPrefix("/") else { return false }
            reportedURL = URL(fileURLWithPath: reportedSource)
        }
        return reportedURL.standardizedFileURL.path
            == expectedSourceURL.standardizedFileURL.path
    }
}

public enum TimeMachineDestinationInformationError: Error, Equatable, LocalizedError {
    case invalidPropertyList

    public var errorDescription: String? {
        switch self {
        case .invalidPropertyList:
            "macOS returned invalid Time Machine destination information. No destination was changed."
        }
    }
}

public struct TimeMachineDestinationInformation: Equatable, Sendable {
    public var matchingIdentifier: String?
    public var knownIdentifiers: Set<String>

    public init(
        matchingIdentifier: String?,
        knownIdentifiers: Set<String>
    ) {
        self.matchingIdentifier = matchingIdentifier
        self.knownIdentifiers = knownIdentifiers
    }
}

/// Parses the public `tmutil destinationinfo -X` property-list surface. The
/// parser is shared by the user-session observer and privileged mutation
/// boundary so both apply the same identifier and mount-point semantics.
public enum TimeMachineDestinationInformationParser {
    public static func parse(
        _ data: Data,
        matchingMountPoint mountPoint: String?
    ) throws -> TimeMachineDestinationInformation {
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            )
        } catch {
            throw TimeMachineDestinationInformationError.invalidPropertyList
        }
        return TimeMachineDestinationInformation(
            matchingIdentifier: mountPoint.flatMap {
                findDestinationIdentifier(
                    in: propertyList,
                    matchingMountPoint: $0
                )
            },
            knownIdentifiers: findDestinationIdentifiers(in: propertyList)
        )
    }

    private static func findDestinationIdentifiers(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            var identifiers = Set<String>()
            for key in ["DestinationID", "ID", "DestinationIdentifier"] {
                if let identifier = dictionary[key] as? String,
                   let canonical = UUID(uuidString: identifier)?.uuidString {
                    identifiers.insert(canonical)
                }
            }
            for nested in dictionary.values {
                identifiers.formUnion(findDestinationIdentifiers(in: nested))
            }
            return identifiers
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) {
                $0.formUnion(findDestinationIdentifiers(in: $1))
            }
        }
        return []
    }

    private static func findDestinationIdentifier(
        in value: Any,
        matchingMountPoint mountPoint: String
    ) -> String? {
        if let dictionary = value as? [String: Any] {
            let values = dictionary.values
            if values.contains(where: { ($0 as? String) == mountPoint }) {
                for key in ["DestinationID", "ID", "DestinationIdentifier"] {
                    if let identifier = dictionary[key] as? String,
                       let canonical = UUID(uuidString: identifier)?.uuidString {
                        return canonical
                    }
                }
            }
            for nested in values {
                if let result = findDestinationIdentifier(
                    in: nested,
                    matchingMountPoint: mountPoint
                ) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = findDestinationIdentifier(
                    in: nested,
                    matchingMountPoint: mountPoint
                ) {
                    return result
                }
            }
        }
        return nil
    }
}

public enum TimeMachineAPFSVolumeRoleError: Error, Equatable, LocalizedError {
    case invalidPropertyList

    public var errorDescription: String? {
        switch self {
        case .invalidPropertyList:
            "macOS returned invalid APFS volume role information. No Time Machine destination was changed."
        }
    }
}

/// Parses the public `diskutil apfs list -plist` surface. Callers still verify
/// the mounted APFS device and mount point independently; this parser proves
/// that the exact device macOS attached carries the Backup role required by
/// Time Machine.
public enum TimeMachineAPFSVolumeRoleParser {
    public static func hasBackupRole(
        _ data: Data,
        deviceIdentifier: String
    ) throws -> Bool {
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            )
        } catch {
            throw TimeMachineAPFSVolumeRoleError.invalidPropertyList
        }
        guard
            let root = propertyList as? [String: Any],
            let containers = root["Containers"] as? [Any]
        else {
            throw TimeMachineAPFSVolumeRoleError.invalidPropertyList
        }
        for containerValue in containers {
            guard
                let container = containerValue as? [String: Any],
                let volumes = container["Volumes"] as? [Any]
            else {
                throw TimeMachineAPFSVolumeRoleError.invalidPropertyList
            }
            for volumeValue in volumes {
                guard
                    let volume = volumeValue as? [String: Any],
                    let observedIdentifier = volume["DeviceIdentifier"] as? String
                else {
                    throw TimeMachineAPFSVolumeRoleError.invalidPropertyList
                }
                guard observedIdentifier == deviceIdentifier else { continue }
                guard let rolesValue = volume["Roles"] else { return false }
                guard let roles = rolesValue as? [String] else {
                    throw TimeMachineAPFSVolumeRoleError.invalidPropertyList
                }
                return roles.contains {
                    $0.caseInsensitiveCompare("Backup") == .orderedSame
                }
            }
        }
        return false
    }
}

/// A monotonic, shared deadline for a sequence of subprocesses. Each subprocess
/// receives only the time left in the enclosing operation instead of restarting
/// the timeout for every command.
public struct TimeMachineSetupDeadline: Equatable, Sendable {
    private static let nanosecondsPerSecond = 1_000_000_000.0

    public let uptimeNanoseconds: UInt64

    public init(
        duration: TimeInterval,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let durationNanoseconds: UInt64
        if duration.isNaN || duration <= 0 {
            durationNanoseconds = 0
        } else if !duration.isFinite
                    || duration >= Double(UInt64.max) / Self.nanosecondsPerSecond
        {
            durationNanoseconds = UInt64.max
        } else {
            durationNanoseconds = UInt64(
                (duration * Self.nanosecondsPerSecond).rounded(.up)
            )
        }
        let (deadline, overflowed) = nowUptimeNanoseconds.addingReportingOverflow(
            durationNanoseconds
        )
        uptimeNanoseconds = overflowed ? UInt64.max : deadline
    }

    public func remainingTime(
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> TimeInterval {
        guard nowUptimeNanoseconds < uptimeNanoseconds else {
            return 0
        }
        return TimeInterval(uptimeNanoseconds - nowUptimeNanoseconds)
            / Self.nanosecondsPerSecond
    }
}

@objc public protocol TimeMachineSetupHelperXPC {
    func verifyReadiness(
        withReply reply: @escaping (Data?, Data?) -> Void
    )

    func execute(
        _ requestData: Data,
        withReply reply: @escaping (Data?, Data?) -> Void
    )
}

public struct TimeMachineSetupHelperReadiness: Codable, Equatable, Sendable {
    public var codeHash: Data

    public init(codeHash: Data) {
        self.codeHash = codeHash
    }
}

public enum TimeMachineSetupHelperReadinessPolicy {
    public static func isCurrent(
        expectedCodeHash: Data,
        observedCodeHash: Data
    ) -> Bool {
        DeltaCodeSigningPeerValidator.matches(
            expectedCodeHash: expectedCodeHash,
            observedCodeHash: observedCodeHash
        )
    }
}

public enum TimeMachineSetupOperation: String, Codable, Sendable {
    case registerDestination
    case removeDestination
}

public struct TimeMachineSetupRequest: Codable, Equatable, Sendable {
    public var operation: TimeMachineSetupOperation
    public var repositoryID: UUID
    public var mountSessionID: UUID?
    public var storeID: UUID
    public var volumeName: String
    public var imageCapacityBytes: Int64
    public var timeMachineDestinationID: String?

    public init(
        operation: TimeMachineSetupOperation,
        repositoryID: UUID,
        mountSessionID: UUID? = nil,
        storeID: UUID,
        volumeName: String,
        imageCapacityBytes: Int64,
        timeMachineDestinationID: String? = nil
    ) {
        self.operation = operation
        self.repositoryID = repositoryID
        self.mountSessionID = mountSessionID
        self.storeID = storeID
        self.volumeName = volumeName
        self.imageCapacityBytes = imageCapacityBytes
        self.timeMachineDestinationID = timeMachineDestinationID
    }
}

public struct TimeMachineSetupResult: Codable, Equatable, Sendable {
    public var fileSystemMountPoint: String?
    public var timeMachineMountPoint: String?
    public var deviceIdentifier: String?
    public var timeMachineDestinationID: String?
    public var hasUnresolvedSavedDestination: Bool

    public init(
        fileSystemMountPoint: String? = nil,
        timeMachineMountPoint: String? = nil,
        deviceIdentifier: String? = nil,
        timeMachineDestinationID: String? = nil,
        hasUnresolvedSavedDestination: Bool = false
    ) {
        self.fileSystemMountPoint = fileSystemMountPoint
        self.timeMachineMountPoint = timeMachineMountPoint
        self.deviceIdentifier = deviceIdentifier
        self.timeMachineDestinationID = timeMachineDestinationID
        self.hasUnresolvedSavedDestination = hasUnresolvedSavedDestination
    }
}

public enum TimeMachineFileSystemResidualState: String, Codable, Equatable, Sendable {
    case mounted
    case unmounted
    case unknown
}

public struct TimeMachineSetupFailure: Codable, Equatable, Sendable {
    public var message: String
    public var fileSystemState: TimeMachineFileSystemResidualState

    public init(
        message: String,
        fileSystemState: TimeMachineFileSystemResidualState
    ) {
        self.message = message
        self.fileSystemState = fileSystemState
    }
}

public enum TimeMachineDestinationIdentityPolicyError: Error, Equatable, LocalizedError {
    case invalidDestinationIdentifier
    case destinationIdentityCannotBeVerified

    public var errorDescription: String? {
        switch self {
        case .invalidDestinationIdentifier:
            "macOS returned an invalid Time Machine destination identifier."
        case .destinationIdentityCannotBeVerified:
            "Delta cannot safely match this disk to its existing Time Machine destination. Open Time Machine Settings, remove the old destination, then connect the disk again."
        }
    }
}

public enum TimeMachineDestinationRegistrationDecision: Equatable, Sendable {
    case useExisting(String)
    case addDestination
}

/// Registration must never add a second global destination merely because a
/// currently attached disk failed path matching. A persisted identifier may
/// detect that cleanup is still required, but only an identifier matched to
/// the attached sparsebundle authorizes reuse.
public enum TimeMachineDestinationRegistrationPolicy {
    public static func decision(
        requestedIdentifier: String?,
        mountedIdentifier: String?,
        knownIdentifiers: Set<String>
    ) throws -> TimeMachineDestinationRegistrationDecision {
        let known = canonicalIdentifiers(knownIdentifiers)
        if let mountedIdentifier {
            let mounted = try canonicalIdentifier(mountedIdentifier)
            if let requestedIdentifier,
               let requested = UUID(uuidString: requestedIdentifier)?.uuidString,
               requested != mounted,
               known.contains(requested) {
                throw TimeMachineDestinationIdentityPolicyError
                    .destinationIdentityCannotBeVerified
            }
            return .useExisting(mounted)
        }
        guard let requestedIdentifier else {
            return .addDestination
        }
        let requested = try canonicalIdentifier(requestedIdentifier)
        guard !known.contains(requested) else {
            throw TimeMachineDestinationIdentityPolicyError
                .destinationIdentityCannotBeVerified
        }
        return .addDestination
    }
}

public struct TimeMachineDestinationRemovalDecision: Equatable, Sendable {
    public var identifierToRemove: String?
    public var hasUnresolvedSavedDestination: Bool

    public init(
        identifierToRemove: String?,
        hasUnresolvedSavedDestination: Bool
    ) {
        self.identifierToRemove = identifierToRemove
        self.hasUnresolvedSavedDestination = hasUnresolvedSavedDestination
    }
}

/// Removing a Time Machine destination is destructive global configuration.
/// Only an identifier discovered from the sparsebundle that is attached right
/// now is authoritative. A persisted identifier may establish that cleanup is
/// still needed, but must never authorize removing an otherwise-unmatched
/// destination from macOS.
public enum TimeMachineDestinationRemovalPolicy {
    public static func decision(
        requestedIdentifier: String?,
        mountedIdentifier: String?,
        knownIdentifiers: Set<String>
    ) throws -> TimeMachineDestinationRemovalDecision {
        let known = canonicalIdentifiers(knownIdentifiers)
        if let mountedIdentifier {
            let mounted = try canonicalIdentifier(mountedIdentifier)
            let requested = requestedIdentifier.flatMap {
                UUID(uuidString: $0)?.uuidString
            }
            return TimeMachineDestinationRemovalDecision(
                identifierToRemove: mounted,
                hasUnresolvedSavedDestination: requested.map {
                    $0 != mounted && known.contains($0)
                } ?? false
            )
        }
        guard let requestedIdentifier else {
            return TimeMachineDestinationRemovalDecision(
                identifierToRemove: nil,
                hasUnresolvedSavedDestination: false
            )
        }
        let requested = try canonicalIdentifier(requestedIdentifier)
        guard !known.contains(requested) else {
            throw TimeMachineDestinationIdentityPolicyError
                .destinationIdentityCannotBeVerified
        }
        return TimeMachineDestinationRemovalDecision(
            identifierToRemove: nil,
            hasUnresolvedSavedDestination: false
        )
    }
}

private func canonicalIdentifiers(_ identifiers: Set<String>) -> Set<String> {
    Set(identifiers.compactMap { UUID(uuidString: $0)?.uuidString })
}

private func canonicalIdentifier(_ identifier: String) throws -> String {
    guard let uuid = UUID(uuidString: identifier) else {
        throw TimeMachineDestinationIdentityPolicyError.invalidDestinationIdentifier
    }
    return uuid.uuidString
}

public enum TimeMachineSetupClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case unavailable(String)
    case operationFailed(message: String, fileSystemState: TimeMachineFileSystemResidualState)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Delta's Time Machine setup helper returned an invalid response."
        case let .unavailable(message):
            "Delta's Time Machine setup helper is unavailable: \(message)"
        case let .operationFailed(message, _):
            message
        case .timedOut:
            "Delta's Time Machine setup helper did not finish in time."
        }
    }

    public var fileSystemState: TimeMachineFileSystemResidualState? {
        guard case let .operationFailed(_, fileSystemState) = self else {
            return nil
        }
        return fileSystemState
    }
}

public enum TimeMachineSetupHelperReadinessError: Error, Equatable, LocalizedError {
    case invalidResponse
    case unavailable(String)
    case timedOut
    case executableMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Delta's Time Machine setup helper returned an invalid readiness response."
        case let .unavailable(message):
            "Delta's Time Machine setup helper is unavailable: \(message)"
        case .timedOut:
            "Delta's Time Machine setup helper did not become ready in time."
        case .executableMismatch:
            "macOS launched a Time Machine setup helper that does not match this installed Delta app."
        }
    }
}

public struct TimeMachineSetupHelperClient: Sendable {
    public static let machServiceName = "com.delta.backup.timemachine.helper"

    public init() {}

    public func verifyReadiness(
        expectedCodeHash: Data,
        timeout: TimeInterval = TimeMachineSetupExecutionPolicy
            .helperReadinessTimeout
    ) throws {
        guard !expectedCodeHash.isEmpty, expectedCodeHash.count <= 64 else {
            throw TimeMachineSetupHelperReadinessError.invalidResponse
        }
        let connection = makeConnection()
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedSetupReadinessResult()
        connection.invalidationHandler = {
            result.finish(
                .failure(.unavailable("The helper connection closed."))
            )
            semaphore.signal()
        }
        connection.interruptionHandler = {
            result.finish(
                .failure(.unavailable("The helper connection was interrupted."))
            )
            semaphore.signal()
        }
        connection.activate()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.finish(.failure(.unavailable(error.localizedDescription)))
            semaphore.signal()
        }) as? TimeMachineSetupHelperXPC else {
            connection.invalidate()
            throw TimeMachineSetupHelperReadinessError.unavailable(
                "The helper protocol is unavailable."
            )
        }
        proxy.verifyReadiness { data, failureData in
            if
                let failureData,
                let failure = try? JSONDecoder().decode(
                    TimeMachineSetupFailure.self,
                    from: failureData
                )
            {
                result.finish(.failure(.unavailable(failure.message)))
            } else if
                let data,
                let decoded = try? JSONDecoder().decode(
                    TimeMachineSetupHelperReadiness.self,
                    from: data
                )
            {
                result.finish(.success(decoded))
            } else {
                result.finish(.failure(.invalidResponse))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            connection.invalidate()
            throw TimeMachineSetupHelperReadinessError.timedOut
        }
        connection.invalidate()
        let readiness = try result.value().get()
        guard TimeMachineSetupHelperReadinessPolicy.isCurrent(
            expectedCodeHash: expectedCodeHash,
            observedCodeHash: readiness.codeHash
        ) else {
            throw TimeMachineSetupHelperReadinessError.executableMismatch
        }
    }

    public func execute(
        _ request: TimeMachineSetupRequest,
        timeout: TimeInterval = TimeMachineSetupExecutionPolicy.clientReplyTimeout
    ) throws -> TimeMachineSetupResult {
        let connection = makeConnection()
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedSetupResult()
        connection.invalidationHandler = {
            result.finish(.failure(.unavailable("The helper connection closed.")))
            semaphore.signal()
        }
        connection.interruptionHandler = {
            result.finish(.failure(.unavailable("The helper connection was interrupted.")))
            semaphore.signal()
        }
        connection.activate()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.finish(.failure(.unavailable(error.localizedDescription)))
            semaphore.signal()
        }) as? TimeMachineSetupHelperXPC else {
            connection.invalidate()
            throw TimeMachineSetupClientError.unavailable("The helper protocol is unavailable.")
        }
        var requestData = try JSONEncoder().encode(request)
        defer { requestData.resetBytes(in: requestData.indices) }
        guard requestData.count <= TimeMachineSetupExecutionPolicy.maximumRequestBytes else {
            connection.invalidate()
            throw TimeMachineSetupClientError.invalidResponse
        }
        proxy.execute(requestData) { data, failureData in
            if
                let failureData,
                let failure = try? JSONDecoder().decode(
                    TimeMachineSetupFailure.self,
                    from: failureData
                )
            {
                result.finish(
                    .failure(
                        .operationFailed(
                            message: failure.message,
                            fileSystemState: failure.fileSystemState
                        )
                    )
                )
            } else if
                let data,
                let decoded = try? JSONDecoder().decode(TimeMachineSetupResult.self, from: data)
            {
                result.finish(.success(decoded))
            } else {
                result.finish(.failure(.invalidResponse))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            connection.invalidate()
            throw TimeMachineSetupClientError.timedOut
        }
        connection.invalidate()
        return try result.value().get()
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: TimeMachineSetupHelperXPC.self)
        connection.setCodeSigningRequirement(
            DeltaCodeSigningRequirement.designated(
                identifier: "com.delta.backup.timemachine-helper"
            )
        )
        return connection
    }
}

private final class LockedSetupReadinessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<
        TimeMachineSetupHelperReadiness,
        TimeMachineSetupHelperReadinessError
    >?

    func finish(
        _ result: Result<
            TimeMachineSetupHelperReadiness,
            TimeMachineSetupHelperReadinessError
        >
    ) {
        lock.lock()
        if stored == nil {
            stored = result
        }
        lock.unlock()
    }

    func value() -> Result<
        TimeMachineSetupHelperReadiness,
        TimeMachineSetupHelperReadinessError
    > {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(.invalidResponse)
    }
}

private final class LockedSetupResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<TimeMachineSetupResult, TimeMachineSetupClientError>?

    func finish(_ result: Result<TimeMachineSetupResult, TimeMachineSetupClientError>) {
        lock.lock()
        if stored == nil {
            stored = result
        }
        lock.unlock()
    }

    func value() -> Result<TimeMachineSetupResult, TimeMachineSetupClientError> {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(.invalidResponse)
    }
}
