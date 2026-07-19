import DeltaTimeMachineIPC
import CryptoKit
import Foundation
import FSKit

#if canImport(ServiceManagement)
@preconcurrency import ServiceManagement
#endif

public enum TimeMachineFileSystemExtensionStatus: Equatable, Sendable {
    case enabled
    case disabled
    case notInstalled
    case unavailable(String)

    public var displayName: String {
        switch self {
        case .enabled: "Ready"
        case .disabled: "Needs Approval"
        case .notInstalled: "Needs Reinstall"
        case .unavailable: "Unavailable"
        }
    }

    public var isReady: Bool {
        self == .enabled
    }
}

public struct TimeMachineFileSystemModuleObservation: Equatable, Sendable {
    public var bundleIdentifier: String
    public var url: URL
    public var isEnabled: Bool

    public init(bundleIdentifier: String, url: URL, isEnabled: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.isEnabled = isEnabled
    }
}

public struct TimeMachineFileSystemExtensionProbe: Sendable {
    public static let bundleIdentifier = "com.delta.backup.timemachine-filesystem"
    public static let executableRelativePath =
        "Contents/Extensions/DeltaTimeMachineFS.appex/Contents/MacOS/DeltaTimeMachineFS"

    public init() {}

    public func check(bundle: Bundle = .main) async -> TimeMachineFileSystemExtensionStatus {
        do {
            let extensions = try await FSClient.shared.installedExtensions
            let expectedURL = bundle.bundleURL
                .appendingPathComponent("Contents/Extensions/DeltaTimeMachineFS.appex")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            return Self.status(
                observations: extensions.map {
                    TimeMachineFileSystemModuleObservation(
                        bundleIdentifier: $0.bundleIdentifier,
                        url: $0.url,
                        isEnabled: $0.isEnabled
                    )
                },
                expectedURL: expectedURL
            )
        } catch {
            return .unavailable(SensitiveLogRedactor.redact(error.localizedDescription))
        }
    }

    public static func status(
        observations: [TimeMachineFileSystemModuleObservation],
        expectedURL: URL
    ) -> TimeMachineFileSystemExtensionStatus {
        let expected = expectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let module = observations.first(where: {
            $0.bundleIdentifier == bundleIdentifier
                && $0.url.standardizedFileURL.resolvingSymlinksInPath()
                    == expected
        }) else {
            if observations.contains(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) {
                return .unavailable(
                    "macOS registered a different copy of Delta's File System Extension. Keep the installed Delta app in Applications, then reopen it."
                )
            }
            return .notInstalled
        }
        return module.isEnabled ? .enabled : .disabled
    }
}

public enum TimeMachineInstalledComponentLayout {
    public static func applicationBundleURL(
        containingExecutable executableURL: URL
    ) -> URL? {
        let path = executableURL.standardizedFileURL.path
        guard
            let contentsRange = path.range(of: "/Contents/", options: .backwards)
        else {
            return nil
        }
        let applicationPath = String(path[..<contentsRange.lowerBound])
        guard applicationPath.hasSuffix(".app") else { return nil }
        return URL(fileURLWithPath: applicationPath, isDirectory: true)
            .standardizedFileURL
    }

    public static func fileSystemExtensionExecutableURL(
        inApplicationBundle applicationBundleURL: URL
    ) -> URL {
        applicationBundleURL.appendingPathComponent(
            TimeMachineFileSystemExtensionProbe.executableRelativePath
        )
    }

    public static func currentFileSystemExtensionCodeHash() throws -> Data {
        let executableURL = try DeltaCodeSigningIdentity
            .currentProcessExecutableURL()
        guard let applicationBundleURL = applicationBundleURL(
            containingExecutable: executableURL
        ) else {
            throw DeltaCodeSigningIdentityError.missingExecutableURL
        }
        return try DeltaCodeSigningIdentity.staticCodeHash(
            at: fileSystemExtensionExecutableURL(
                inApplicationBundle: applicationBundleURL
            )
        )
    }
}

public enum TimeMachineServiceController {
    public static let plistName = "com.delta.backup.timemachine.service.plist"
    public static let reloadNotificationName = Notification.Name("com.delta.backup.time-machine.reload")
    public static let codeSigningIdentifier = DeltaTimeMachineIPCIdentity
        .storageServiceIdentifier

    public static func register() throws {
        guard status() != .enabled, status() != .requiresApproval else { return }
        try LaunchAgentController.register(plistName: plistName)
    }

    public static func unregister() throws {
        try LaunchAgentController.unregister(plistName: plistName)
    }

    public static func reregister() async throws {
        try await LaunchAgentController.reregister(plistName: plistName)
    }

    public static func status() -> LaunchAgentRegistrationStatus {
        LaunchAgentController.status(plistName: plistName)
    }
}

public enum TimeMachineSetupHelperController {
    public static let plistName = "com.delta.backup.timemachine.helper.plist"
    public static let executableRelativePath =
        "Contents/Library/LaunchServices/DeltaTimeMachineHelper"

    public static func register() throws {
        #if canImport(ServiceManagement)
        guard status() != .enabled, status() != .requiresApproval else { return }
        try SMAppService.daemon(plistName: plistName).register()
        #endif
    }

    public static func unregister() throws {
        #if canImport(ServiceManagement)
        try SMAppService.daemon(plistName: plistName).unregister()
        #endif
    }

    public static func reregister() async throws {
        #if canImport(ServiceManagement)
        let service = SMAppService.daemon(plistName: plistName)
        try await ServiceManagementRegistration.reregister(service)
        #endif
    }

    public static func status() -> LaunchAgentRegistrationStatus {
        #if canImport(ServiceManagement)
        return ServiceManagementRegistration.status(
            of: SMAppService.daemon(plistName: plistName)
        )
        #else
        return .unavailable
        #endif
    }

    public static func installedCodeHash(bundle: Bundle = .main) throws -> Data {
        try DeltaCodeSigningIdentity.staticCodeHash(
            at: bundle.bundleURL.appendingPathComponent(executableRelativePath)
        )
    }
}

public enum TimeMachineSystemRegistrationFingerprint {
    static let artifactRelativePaths = [
        "Contents/Resources/DeltaTimeMachineService",
        "Contents/Library/LaunchAgents/\(TimeMachineServiceController.plistName)",
        TimeMachineSetupHelperController.executableRelativePath,
        "Contents/Library/LaunchDaemons/\(TimeMachineSetupHelperController.plistName)",
        TimeMachineFileSystemExtensionProbe.executableRelativePath,
        "Contents/Extensions/DeltaTimeMachineFS.appex/Contents/Info.plist"
    ]

    public static func current(bundle: Bundle = .main) -> String? {
        current(bundleURL: bundle.bundleURL)
    }

    static func current(bundleURL: URL) -> String? {
        do {
            var hasher = SHA256()
            update(
                &hasher,
                with: Data(
                    bundleURL.standardizedFileURL.resolvingSymlinksInPath().path.utf8
                )
            )
            for relativePath in artifactRelativePaths {
                try update(
                    &hasher,
                    withContentsOf: bundleURL.appendingPathComponent(relativePath)
                )
            }
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        } catch {
            return nil
        }
    }

    public static func fingerprint(artifacts: [Data]) -> String {
        var hasher = SHA256()
        for artifact in artifacts {
            update(&hasher, with: artifact)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(bundlePath: String, artifacts: [Data]) -> String {
        var hasher = SHA256()
        update(&hasher, with: Data(bundlePath.utf8))
        for artifact in artifacts {
            update(&hasher, with: artifact)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes bundled artifacts incrementally so update reconciliation never
    /// needs to retain several executable images in memory at once.
    private static func update(
        _ hasher: inout SHA256,
        withContentsOf url: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let expectedLength = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var encodedLength = expectedLength.bigEndian
        withUnsafeBytes(of: &encodedLength) {
            hasher.update(bufferPointer: $0)
        }
        var observedLength: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            let (nextLength, overflowed) = observedLength.addingReportingOverflow(
                UInt64(chunk.count)
            )
            guard !overflowed, nextLength <= expectedLength else {
                throw CocoaError(.fileReadCorruptFile)
            }
            observedLength = nextLength
            hasher.update(data: chunk)
        }
        guard observedLength == expectedLength else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func update(_ hasher: inout SHA256, with data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }
}

public enum TimeMachineSystemRegistrationMaintenanceAction: Equatable, Sendable {
    case none
    case reregister
}

public enum TimeMachineSystemRegistrationRefreshError: Error, LocalizedError {
    case mountedDiskPreventsRefresh
    case installedComponentsChanged

    public var errorDescription: String? {
        switch self {
        case .mountedDiskPreventsRefresh:
            "Disconnect every Delta Time Machine disk before refreshing system support."
        case .installedComponentsChanged:
            "Delta's installed Time Machine components changed before the disk connection began. Wait for system support to refresh, then try again."
        }
    }
}

public enum TimeMachineSystemAccessRegistrationPolicy {
    /// Service Management may throw `EPERM` after successfully creating a
    /// registration that is waiting for the user's Login Items approval. The
    /// post-call status is authoritative for that expected transition.
    public static func accepted(status: LaunchAgentRegistrationStatus) -> Bool {
        ServiceManagementReregistrationPolicy.accepts(status)
    }
}

public enum TimeMachineSystemAccessRequestAction: Equatable, Sendable {
    case none
    case register
    case reregister
}

public struct TimeMachineSystemAccessRepairScope: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let backgroundService = Self(rawValue: 1 << 0)
    public static let setupHelper = Self(rawValue: 1 << 1)
    public static let all: Self = [.backgroundService, .setupHelper]
}

public enum TimeMachineSystemAccessPostRegistrationAction: Equatable, Sendable {
    case none
    case recordCurrentFingerprint
    case repair(TimeMachineSystemAccessRepairScope)
}

public enum TimeMachineSystemAccessRequestPolicy {
    /// An explicit user request may repair an enabled registration that still
    /// points at an older or moved app. Automatic update reconciliation avoids
    /// unregistering the privileged helper because that can require renewed
    /// Login Items approval; the explicit Set Up action is the supported
    /// recovery boundary for that Service Management transition.
    public static func action(
        serviceStatus: LaunchAgentRegistrationStatus,
        helperStatus: LaunchAgentRegistrationStatus,
        registeredFingerprint: String?,
        currentFingerprint: String?
    ) -> TimeMachineSystemAccessRequestAction {
        guard
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: serviceStatus),
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: helperStatus)
        else {
            return .register
        }
        guard serviceStatus == .enabled, helperStatus == .enabled else {
            return .none
        }
        guard let currentFingerprint else {
            return .none
        }
        return registeredFingerprint == currentFingerprint ? .none : .reregister
    }
}

public enum TimeMachineSystemAccessPostRegistrationPolicy {
    /// A successful registration is already bound to the component in the
    /// calling app. When a mixed old/new registration is repaired, refresh
    /// only components that were accepted before this request. Tearing down a
    /// component that was just registered can discard its privileged approval
    /// and force a second, unnecessary authorization cycle.
    public static func action(
        priorServiceStatus: LaunchAgentRegistrationStatus,
        priorHelperStatus: LaunchAgentRegistrationStatus,
        serviceStatus: LaunchAgentRegistrationStatus,
        helperStatus: LaunchAgentRegistrationStatus,
        registeredFingerprint: String?,
        currentFingerprint: String?
    ) -> TimeMachineSystemAccessPostRegistrationAction {
        guard
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: serviceStatus),
            TimeMachineSystemAccessRegistrationPolicy.accepted(status: helperStatus),
            let currentFingerprint
        else {
            return .none
        }
        if registeredFingerprint == currentFingerprint {
            return .recordCurrentFingerprint
        }

        let serviceWasRegistered =
            !TimeMachineSystemAccessRegistrationPolicy.accepted(status: priorServiceStatus)
                && TimeMachineSystemAccessRegistrationPolicy.accepted(status: serviceStatus)
        let helperWasRegistered =
            !TimeMachineSystemAccessRegistrationPolicy.accepted(status: priorHelperStatus)
                && TimeMachineSystemAccessRegistrationPolicy.accepted(status: helperStatus)

        guard serviceWasRegistered || serviceStatus == .enabled else {
            return .none
        }
        guard helperWasRegistered || helperStatus == .enabled else {
            return .none
        }

        var scope: TimeMachineSystemAccessRepairScope = []
        if !serviceWasRegistered, serviceStatus == .enabled {
            scope.insert(.backgroundService)
        }
        if !helperWasRegistered, helperStatus == .enabled {
            scope.insert(.setupHelper)
        }
        if !scope.isEmpty {
            return .repair(scope)
        }
        if serviceWasRegistered, helperWasRegistered {
            return .recordCurrentFingerprint
        }
        return .none
    }
}

public enum TimeMachineSystemAccessRepairError: Error, LocalizedError {
    case registrationIncomplete

    public var errorDescription: String? {
        switch self {
        case .registrationIncomplete:
            "macOS did not complete the Time Machine background-item registration. Review Login Items, then try again."
        }
    }
}

public enum TimeMachineSystemRegistrationMaintenancePolicy {
    public static func isCurrent(
        serviceStatus: LaunchAgentRegistrationStatus,
        helperStatus: LaunchAgentRegistrationStatus,
        registeredFingerprint: String?,
        currentFingerprint: String?
    ) -> Bool {
        serviceStatus == .enabled
            && helperStatus == .enabled
            && currentFingerprint != nil
            && registeredFingerprint == currentFingerprint
    }

    public static func action(
        hasTimeMachineDestinations: Bool,
        updateReadiness: DeltaSoftwareUpdateReadiness,
        serviceStatus: LaunchAgentRegistrationStatus,
        helperStatus: LaunchAgentRegistrationStatus,
        registeredFingerprint: String?,
        currentFingerprint: String?
    ) -> TimeMachineSystemRegistrationMaintenanceAction {
        guard
            hasTimeMachineDestinations,
            updateReadiness == .ready,
            serviceStatus == .enabled,
            helperStatus == .enabled,
            let currentFingerprint,
            registeredFingerprint != currentFingerprint
        else {
            return .none
        }
        return .reregister
    }
}

public enum TimeMachineSystemRegistrationRetryPolicy {
    public static let retryInterval: TimeInterval = 60

    public static func shouldAttempt(
        currentFingerprint: String,
        lastAttemptFingerprint: String?,
        lastAttemptUptime: TimeInterval?,
        currentUptime: TimeInterval
    ) -> Bool {
        guard lastAttemptFingerprint == currentFingerprint else {
            return true
        }
        guard let lastAttemptUptime else {
            return false
        }
        guard currentUptime >= lastAttemptUptime else {
            return true
        }
        return currentUptime - lastAttemptUptime >= retryInterval
    }
}

public enum TimeMachineSystemRegistrationEventPolicy {
    /// Automatic retries keep the system-support status current, but Activity
    /// should only gain evidence when the observed failure changes. The live
    /// permission status remains authoritative on every attempt.
    public static func shouldRecordFailure(
        previousMessage: String?,
        currentMessage: String
    ) -> Bool {
        previousMessage != currentMessage
    }
}

public enum FileSystemExtensionsGuide {
    public static let settingsURL = LoginItemsGuide.settingsURL
}
