import Darwin
import DeltaCore
import Foundation
import OSLog

private typealias FileSystemStat = statfs

private enum SourceValidationStage: String {
    case sourceResolution
    case sourceCanonicalPath
    case sourceMetadata
    case mountPointLookup
    case mountPointType
    case mountFileSystemLookup
    case mountMissing
    case mountIdentity
    case mountEnumerationCount
    case mountEnumerationCapacity
    case mountEnumerationRead
    case imageMissing
    case imageMountRootMetadata
    case imageLookup
    case imageMetadata
}

private enum SetupHelperError: Error, LocalizedError {
    case invalidRequest
    case invalidCaller
    case invalidSource(SourceValidationStage)
    case operationBusy
    case commandFailed(String)
    case fullDiskAccessRequired
    case operationTimedOut
    case missingAttachedVolume
    case missingBackupRole
    case missingDestinationIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The Time Machine setup request is invalid."
        case .invalidCaller: "The Time Machine setup request did not come from an allowed Delta process."
        case .invalidSource: "Delta's Time Machine source directory failed its ownership or path check."
        case .operationBusy: "Another Delta Time Machine setup operation is still in progress. Try again when it finishes."
        case let .commandFailed(message): message
        case .fullDiskAccessRequired:
            TimeMachineSetupCommandFailurePolicy.fullDiskAccessUserMessage
        case .operationTimedOut: "Delta's privileged Time Machine setup operation exceeded its safety deadline."
        case .missingAttachedVolume: "macOS attached the Time Machine disk image without returning a mounted APFS volume."
        case .missingBackupRole: "macOS did not retain the Backup role on Delta's Time Machine APFS volume. The disk was not added to Time Machine."
        case .missingDestinationIdentifier: "macOS accepted the Time Machine disk but did not return a destination identifier."
        }
    }
}

private final class SetupWorker: NSObject, TimeMachineSetupHelperXPC {
    private struct MountedFileSystem {
        var source: String
        var type: String
        var ignoresOwnership: Bool
    }

    private let callerUserID: uid_t
    private let runner = TimeMachineBinaryProcessRunner()
    private static let operationLock = NSLock()
    private static let logger = Logger(
        subsystem: "com.delta.backup.timemachine-helper",
        category: "Setup"
    )

    init(callerUserID: uid_t) {
        self.callerUserID = callerUserID
    }

    func verifyReadiness(
        withReply reply: @escaping (Data?, Data?) -> Void
    ) {
        do {
            let readiness = TimeMachineSetupHelperReadiness(
                codeHash: try DeltaCodeSigningIdentity.currentProcessCodeHash()
            )
            reply(try JSONEncoder().encode(readiness), nil)
        } catch {
            replyFailure(
                error,
                fileSystemState: .unknown,
                reply: reply
            )
        }
    }

    func execute(
        _ requestData: Data,
        withReply reply: @escaping (Data?, Data?) -> Void
    ) {
        guard requestData.count <= TimeMachineSetupExecutionPolicy.maximumRequestBytes else {
            replyFailure(
                SetupHelperError.invalidRequest,
                fileSystemState: .unknown,
                reply: reply
            )
            return
        }
        guard Self.operationLock.try() else {
            replyFailure(
                SetupHelperError.operationBusy,
                fileSystemState: .unknown,
                reply: reply
            )
            return
        }
        defer { Self.operationLock.unlock() }
        var mutableRequestData = requestData
        defer { mutableRequestData.resetBytes(in: mutableRequestData.indices) }
        var decodedRequest: TimeMachineSetupRequest?
        do {
            let request = try JSONDecoder().decode(
                TimeMachineSetupRequest.self,
                from: mutableRequestData
            )
            decodedRequest = request
            let result = try execute(request)
            reply(try JSONEncoder().encode(result), nil)
        } catch {
            replyFailure(
                error,
                fileSystemState: decodedRequest.map {
                    fileSystemState(request: $0)
                } ?? .unknown,
                reply: reply
            )
        }
    }

    private func replyFailure(
        _ error: Error,
        fileSystemState: TimeMachineFileSystemResidualState,
        reply: @escaping (Data?, Data?) -> Void
    ) {
        if case let SetupHelperError.invalidSource(stage) = error {
            Self.logger.error(
                "Time Machine source validation failed at stage: \(stage.rawValue, privacy: .public)"
            )
        }
        let failure = TimeMachineSetupFailure(
            message: SensitiveLogRedactor.redact(error.localizedDescription),
            fileSystemState: fileSystemState
        )
        reply(nil, try? JSONEncoder().encode(failure))
    }

    private func fileSystemState(
        request: TimeMachineSetupRequest
    ) -> TimeMachineFileSystemResidualState {
        do {
            let mountPoint = try TimeMachineRuntimePaths.fileSystemMountPoint(
                repositoryID: request.repositoryID,
                mountSessionID: request.mountSessionID,
                applicationSupportURL: homeDirectory(for: callerUserID)
                    .appendingPathComponent("Library/Application Support/Delta", isDirectory: true)
            )
            return try mountedFileSystem(at: mountPoint) == nil ? .unmounted : .mounted
        } catch {
            return .unknown
        }
    }

    private func execute(_ request: TimeMachineSetupRequest) throws -> TimeMachineSetupResult {
        guard
            callerUserID != 0,
            TimeMachineRepositorySettings.normalizedVolumeName(request.volumeName)
                == request.volumeName,
            request.imageCapacityBytes
                >= TimeMachineRepositorySettings.minimumImageCapacityBytes,
            request.imageCapacityBytes
                <= TimeMachineRepositorySettings.maximumImageCapacityBytes
        else {
            throw SetupHelperError.invalidRequest
        }
        let home = try homeDirectory(for: callerUserID)
        let source = home
            .appendingPathComponent("Library/Application Support/Delta/TimeMachine", isDirectory: true)
            .appendingPathComponent(request.repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("source", isDirectory: true)
        try validateSource(
            source,
            repositoryID: request.repositoryID,
            mountSessionID: request.mountSessionID
        )
        let fileSystemMount = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: request.repositoryID,
            mountSessionID: request.mountSessionID,
            applicationSupportURL: home
                .appendingPathComponent("Library/Application Support/Delta", isDirectory: true)
        )
        let deadline = TimeMachineSetupDeadline(
            duration: TimeMachineSetupExecutionPolicy.operationRuntime
        )

        switch request.operation {
        case .registerDestination:
            return try registerDestination(
                request: request,
                source: source,
                fileSystemMount: fileSystemMount,
                home: home,
                deadline: deadline
            )
        case .removeDestination:
            return try removeDestination(
                request: request,
                source: source,
                fileSystemMount: fileSystemMount,
                home: home,
                deadline: deadline
            )
        }
    }

    private func registerDestination(
        request: TimeMachineSetupRequest,
        source: URL,
        fileSystemMount: URL,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws -> TimeMachineSetupResult {
        var addedDestinationID: String?
        let imageSettings = TimeMachineRepositorySettings(
            storeID: request.storeID,
            volumeName: request.volumeName,
            imageCapacityBytes: request.imageCapacityBytes
        )
        do {
            let mountedFileSystem = try validateUserMountedFileSystem(
                at: fileSystemMount,
                source: source,
                repositoryID: request.repositoryID
            )
            let image = fileSystemMount.appendingPathComponent(
                TimeMachineRuntimePaths.diskImageName(settings: imageSettings),
                isDirectory: true
            )
            guard try diskImageExists(
                at: image,
                mountedRoot: fileSystemMount,
                sourceRoot: source,
                repositoryID: request.repositoryID,
                mountSessionID: request.mountSessionID,
                settings: imageSettings,
                mountedFileSystem: mountedFileSystem,
                expectedOwnerID: callerUserID
            ) else {
                throw SetupHelperError.invalidSource(.imageMissing)
            }
            guard let attached = try attachedVolumeIfPresent(
                for: image,
                home: home,
                deadline: deadline
            ) else {
                throw SetupHelperError.missingAttachedVolume
            }
            try validateAttachedVolume(attached)
            try validateBackupRole(
                deviceIdentifier: attached.deviceIdentifier,
                home: home,
                deadline: deadline
            )
            var destinationSnapshot = try destinationInformation(
                matchingMountPoint: attached.mountPoint,
                home: home,
                deadline: deadline
            )
            var destinationID: String?
            switch try TimeMachineDestinationRegistrationPolicy.decision(
                requestedIdentifier: request.timeMachineDestinationID,
                mountedIdentifier: destinationSnapshot.matchingIdentifier,
                knownIdentifiers: destinationSnapshot.knownIdentifiers
            ) {
            case let .useExisting(identifier):
                destinationID = identifier
            case .addDestination:
                let identifiersBeforeRegistration = Self.canonicalDestinationIdentifiers(
                    destinationSnapshot.knownIdentifiers
                )
                try validateAttachedVolume(attached)
                try validateBackupRole(
                    deviceIdentifier: attached.deviceIdentifier,
                    home: home,
                    deadline: deadline
                )
                try run(
                    executable: "/usr/bin/tmutil",
                    arguments: ["setdestination", "-a", attached.mountPoint],
                    home: home,
                    deadline: deadline
                )
                destinationSnapshot = try destinationInformation(
                    matchingMountPoint: attached.mountPoint,
                    home: home,
                    deadline: deadline
                )
                let identifiersAfterRegistration = Self.canonicalDestinationIdentifiers(
                    destinationSnapshot.knownIdentifiers
                )
                let newlyRegisteredIdentifiers = identifiersAfterRegistration
                    .subtracting(identifiersBeforeRegistration)
                destinationID = destinationSnapshot.matchingIdentifier.flatMap {
                    UUID(uuidString: $0)?.uuidString
                }
                if destinationID == nil, newlyRegisteredIdentifiers.count == 1 {
                    destinationID = newlyRegisteredIdentifiers.first
                }
                if let destinationID, newlyRegisteredIdentifiers.contains(destinationID) {
                    addedDestinationID = destinationID
                }
            }
            guard let destinationID, !destinationID.isEmpty else {
                throw SetupHelperError.missingDestinationIdentifier
            }
            try validateAttachedVolume(attached)
            try validateBackupRole(
                deviceIdentifier: attached.deviceIdentifier,
                home: home,
                deadline: deadline
            )
            return TimeMachineSetupResult(
                fileSystemMountPoint: fileSystemMount.path,
                timeMachineMountPoint: attached.mountPoint,
                deviceIdentifier: attached.deviceIdentifier,
                timeMachineDestinationID: destinationID
            )
        } catch {
            let rollbackDeadline = TimeMachineSetupDeadline(
                duration: TimeMachineSetupExecutionPolicy.rollbackRuntime
            )
            if let addedDestinationID {
                _ = try? run(
                    executable: "/usr/bin/tmutil",
                    arguments: ["removedestination", addedDestinationID],
                    home: home,
                    deadline: rollbackDeadline
                )
            }
            throw error
        }
    }

    private func removeDestination(
        request: TimeMachineSetupRequest,
        source: URL,
        fileSystemMount: URL,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws -> TimeMachineSetupResult {
        _ = try validateUserMountedFileSystem(
            at: fileSystemMount,
            source: source,
            repositoryID: request.repositoryID
        )
        let image = fileSystemMount.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(
                settings: TimeMachineRepositorySettings(
                    storeID: request.storeID,
                    volumeName: request.volumeName,
                    imageCapacityBytes: request.imageCapacityBytes
                )
            ),
            isDirectory: true
        )
        let attached = try attachedVolumeIfPresent(
            for: image,
            home: home,
            deadline: deadline
        )
        let destinationSnapshot = try destinationInformation(
            matchingMountPoint: attached?.mountPoint,
            home: home,
            deadline: deadline
        )
        let decision = try TimeMachineDestinationRemovalPolicy.decision(
            requestedIdentifier: request.timeMachineDestinationID,
            mountedIdentifier: destinationSnapshot.matchingIdentifier,
            knownIdentifiers: destinationSnapshot.knownIdentifiers
        )
        let destinationID = decision.identifierToRemove
        if let destinationID {
            try run(
                executable: "/usr/bin/tmutil",
                arguments: ["removedestination", destinationID],
                home: home,
                deadline: deadline
            )
        }
        return TimeMachineSetupResult(
            fileSystemMountPoint: fileSystemMount.path,
            timeMachineMountPoint: attached?.mountPoint,
            deviceIdentifier: attached?.deviceIdentifier,
            hasUnresolvedSavedDestination: decision.hasUnresolvedSavedDestination
        )
    }

    @discardableResult
    private func run(
        executable: String,
        arguments: [String],
        home: URL,
        deadline: TimeMachineSetupDeadline,
        timeoutOutputBytes: Int = 1_048_576
    ) throws -> TimeMachineBinaryProcessResult {
        let remainingRuntime = deadline.remainingTime()
        guard remainingRuntime > 0 else {
            throw SetupHelperError.operationTimedOut
        }
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/tmp"
            ],
            standardInput: nil,
            maximumOutputBytes: timeoutOutputBytes,
            maximumRuntime: remainingRuntime
        )
        guard result.exitCode == 0 else {
            if TimeMachineSetupCommandFailurePolicy.requiresFullDiskAccess(
                executablePath: executable,
                standardError: result.standardError
            ) {
                throw SetupHelperError.fullDiskAccessRequired
            }
            let message = SensitiveLogRedactor.redact(result.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupHelperError.commandFailed(
                message.isEmpty
                    ? "\(URL(fileURLWithPath: executable).lastPathComponent) failed with exit \(result.exitCode)."
                    : message
            )
        }
        return result
    }

    private func mountedFileSystem(at mountPoint: URL) throws -> MountedFileSystem? {
        var attributes = stat()
        guard lstat(mountPoint.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw SetupHelperError.invalidSource(.mountPointLookup)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFDIR else {
            throw SetupHelperError.invalidSource(.mountPointType)
        }
        var fileSystem = statfs()
        guard statfs(mountPoint.path, &fileSystem) == 0 else {
            throw SetupHelperError.invalidSource(.mountFileSystemLookup)
        }
        let actualMountPoint = cString(from: &fileSystem.f_mntonname)
        guard actualMountPoint == mountPoint.standardizedFileURL.path else {
            return nil
        }
        return MountedFileSystem(
            source: cString(from: &fileSystem.f_mntfromname),
            type: cString(from: &fileSystem.f_fstypename),
            ignoresOwnership: (
                fileSystem.f_flags & UInt32(bitPattern: MNT_IGNORE_OWNERSHIP)
            ) != 0
        )
    }

    private func hasMountedDeltaFileSystem() throws -> Bool {
        let observedCount = getfsstat(nil, 0, MNT_NOWAIT)
        guard observedCount >= 0 else {
            throw SetupHelperError.invalidSource(.mountEnumerationCount)
        }
        let capacity = Int(observedCount) + 32
        guard capacity <= Int(Int32.max) / MemoryLayout<FileSystemStat>.stride else {
            throw SetupHelperError.invalidSource(.mountEnumerationCapacity)
        }
        var fileSystems = [FileSystemStat](
            repeating: FileSystemStat(),
            count: capacity
        )
        let actualCount = fileSystems.withUnsafeMutableBufferPointer { buffer in
            getfsstat(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<FileSystemStat>.stride),
                MNT_NOWAIT
            )
        }
        guard actualCount >= 0, actualCount < capacity else {
            throw SetupHelperError.invalidSource(.mountEnumerationRead)
        }
        for index in 0..<Int(actualCount) {
            if cString(from: &fileSystems[index].f_fstypename) == "delta-tm" {
                return true
            }
        }
        return false
    }

    private func validateMountedFileSystem(
        _ mounted: MountedFileSystem,
        source: URL
    ) throws {
        guard
            mounted.type == "delta-tm",
            TimeMachineMountedFileSystemIdentity.matches(
                reportedSource: mounted.source,
                expectedSourceURL: source
            )
        else {
            throw SetupHelperError.invalidSource(.mountIdentity)
        }
    }

    private func validateUserMountedFileSystem(
        at mountPoint: URL,
        source: URL,
        repositoryID: UUID
    ) throws -> MountedFileSystem {
        do {
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: callerUserID
            )
        } catch {
            throw SetupHelperError.invalidSource(.sourceMetadata)
        }
        guard let mounted = try mountedFileSystem(at: mountPoint) else {
            throw SetupHelperError.invalidSource(.mountMissing)
        }
        try validateMountedFileSystem(mounted, source: source)
        return mounted
    }

    private func diskImageExists(
        at image: URL,
        mountedRoot: URL,
        sourceRoot: URL,
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        mountedFileSystem: MountedFileSystem,
        expectedOwnerID: uid_t
    ) throws -> Bool {
        let sourceImageExists: Bool
        do {
            sourceImageExists = try TimeMachineRuntimePaths.sourceDiskImageExists(
                sourceDirectory: sourceRoot,
                repositoryID: repositoryID,
                expectedMountSessionID: mountSessionID,
                settings: settings,
                expectedOwnerID: expectedOwnerID
            )
        } catch {
            throw SetupHelperError.invalidSource(.sourceMetadata)
        }
        guard sourceImageExists else { return false }
        var rootAttributes = stat()
        guard
            lstat(mountedRoot.path, &rootAttributes) == 0,
            (rootAttributes.st_mode & S_IFMT) == S_IFDIR,
            TimeMachineMountedOwnershipPolicy.accepts(
                observedOwnerID: rootAttributes.st_uid,
                expectedOwnerID: expectedOwnerID,
                mountIgnoresOwnership: mountedFileSystem.ignoresOwnership
            ),
            (rootAttributes.st_mode & 0o022) == 0
        else {
            throw SetupHelperError.invalidSource(.imageMountRootMetadata)
        }
        var imageAttributes = stat()
        guard lstat(image.path, &imageAttributes) == 0 else {
            if errno == ENOENT { return false }
            throw SetupHelperError.invalidSource(.imageLookup)
        }
        guard
            (imageAttributes.st_mode & S_IFMT) == S_IFDIR,
            imageAttributes.st_dev == rootAttributes.st_dev,
            TimeMachineMountedOwnershipPolicy.accepts(
                observedOwnerID: imageAttributes.st_uid,
                expectedOwnerID: expectedOwnerID,
                mountIgnoresOwnership: mountedFileSystem.ignoresOwnership
            ),
            (imageAttributes.st_mode & 0o022) == 0
        else {
            throw SetupHelperError.invalidSource(.imageMetadata)
        }
        return true
    }

    private func validateAttachedVolume(
        _ attached: (deviceIdentifier: String, mountPoint: String)
    ) throws {
        let mountURL = URL(
            fileURLWithPath: attached.mountPoint,
            isDirectory: true
        )
        let devicePath = "/dev/\(attached.deviceIdentifier)"
        guard
            !attached.mountPoint.utf8.contains(0),
            !attached.deviceIdentifier.utf8.contains(0),
            mountURL.standardizedFileURL.path == attached.mountPoint,
            mountURL.deletingLastPathComponent().path == "/Volumes",
            isDiskVolumeIdentifier(attached.deviceIdentifier)
        else {
            throw SetupHelperError.missingAttachedVolume
        }
        var fileSystem = statfs()
        guard statfs(attached.mountPoint, &fileSystem) == 0 else {
            throw SetupHelperError.missingAttachedVolume
        }
        guard
            cString(from: &fileSystem.f_mntonname) == attached.mountPoint,
            cString(from: &fileSystem.f_mntfromname) == devicePath,
            cString(from: &fileSystem.f_fstypename) == "apfs"
        else {
            throw SetupHelperError.missingAttachedVolume
        }
    }

    private func validateBackupRole(
        deviceIdentifier: String,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws {
        let result = try run(
            executable: "/usr/sbin/diskutil",
            arguments: ["apfs", "list", "-plist"],
            home: home,
            deadline: deadline,
            timeoutOutputBytes: 8 * 1_048_576
        )
        guard try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
            result.standardOutput,
            deviceIdentifier: deviceIdentifier
        ) else {
            throw SetupHelperError.missingBackupRole
        }
    }

    private func isDiskVolumeIdentifier(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("disk") else { return false }
        let suffix = identifier.dropFirst(4)
        guard let separator = suffix.firstIndex(of: "s") else { return false }
        let diskNumber = suffix[..<separator]
        let sliceNumber = suffix[suffix.index(after: separator)...]
        return !diskNumber.isEmpty
            && !sliceNumber.isEmpty
            && diskNumber.allSatisfy(\.isNumber)
            && sliceNumber.allSatisfy(\.isNumber)
    }

    private func cString<Value>(from value: inout Value) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout<Value>.size
            ) {
                String(cString: $0)
            }
        }
    }

    private func attachedVolumeIfPresent(
        for image: URL,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws -> (deviceIdentifier: String, mountPoint: String)? {
        let result = try run(
            executable: "/usr/bin/hdiutil",
            arguments: ["info", "-plist"],
            home: home,
            deadline: deadline,
            timeoutOutputBytes: 4 * 1_048_576
        )
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: result.standardOutput,
                format: nil
            ) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else {
            throw SetupHelperError.missingAttachedVolume
        }
        let expectedPath = image.standardizedFileURL.path
        guard let matching = images.first(where: {
            guard let path = $0["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == expectedPath
        }) else {
            return nil
        }
        guard
            let entities = matching["system-entities"] as? [[String: Any]],
            let entity = entities.first(where: { $0["mount-point"] != nil }),
            let mountPoint = entity["mount-point"] as? String,
            let devicePath = entity["dev-entry"] as? String
        else {
            throw SetupHelperError.missingAttachedVolume
        }
        let attached = (
            deviceIdentifier: URL(fileURLWithPath: devicePath).lastPathComponent,
            mountPoint: mountPoint
        )
        guard
            URL(fileURLWithPath: devicePath).standardizedFileURL.path == devicePath,
            URL(fileURLWithPath: devicePath).deletingLastPathComponent().path == "/dev"
        else {
            throw SetupHelperError.missingAttachedVolume
        }
        try validateAttachedVolume(attached)
        return attached
    }

    private func destinationInformation(
        matchingMountPoint mountPoint: String?,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws -> TimeMachineDestinationInformation {
        let result = try run(
            executable: "/usr/bin/tmutil",
            arguments: ["destinationinfo", "-X"],
            home: home,
            deadline: deadline,
            timeoutOutputBytes: 2 * 1_048_576
        )
        return try TimeMachineDestinationInformationParser.parse(
            result.standardOutput,
            matchingMountPoint: mountPoint
        )
    }

    private static func canonicalDestinationIdentifiers(
        _ identifiers: Set<String>
    ) -> Set<String> {
        Set(identifiers.compactMap { UUID(uuidString: $0)?.uuidString })
    }

    private func homeDirectory(for userID: uid_t) throws -> URL {
        guard let record = getpwuid(userID), let path = record.pointee.pw_dir else {
            throw SetupHelperError.invalidCaller
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func validateSource(
        _ source: URL,
        repositoryID: UUID,
        mountSessionID: UUID?
    ) throws {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(source.path, &resolved) != nil else {
            throw SetupHelperError.invalidSource(.sourceResolution)
        }
        let terminator = resolved.firstIndex(of: 0) ?? resolved.endIndex
        let resolvedPath = String(
            decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard
            resolvedPath == source.standardizedFileURL.path
        else {
            throw SetupHelperError.invalidSource(.sourceCanonicalPath)
        }
        do {
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: callerUserID,
                expectedMountSessionID: mountSessionID
            )
        } catch {
            throw SetupHelperError.invalidSource(.sourceMetadata)
        }
    }

}

private final class SetupListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else {
            return false
        }
        connection.setCodeSigningRequirement(
            DeltaCodeSigningRequirement.designated(identifier: "com.delta.backup")
        )
        connection.exportedInterface = NSXPCInterface(with: TimeMachineSetupHelperXPC.self)
        connection.exportedObject = SetupWorker(callerUserID: connection.effectiveUserIdentifier)
        connection.activate()
        return true
    }
}

private let delegate = SetupListenerDelegate()
private let listener = NSXPCListener(machServiceName: TimeMachineSetupHelperClient.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
