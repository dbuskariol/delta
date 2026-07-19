import Darwin
import Foundation

public struct TimeMachineSystemDiskObservation: Equatable, Sendable {
    public var fileSystemState: TimeMachineFileSystemResidualState
    public var diskImagePresent: Bool
    public var timeMachineMountPoint: String?
    public var deviceIdentifier: String?
    public var hasBackupRole: Bool
    public var matchingDestinationIdentifier: String?
    public var knownDestinationIdentifiers: Set<String>

    public init(
        fileSystemState: TimeMachineFileSystemResidualState,
        diskImagePresent: Bool,
        timeMachineMountPoint: String?,
        deviceIdentifier: String?,
        hasBackupRole: Bool,
        matchingDestinationIdentifier: String?,
        knownDestinationIdentifiers: Set<String>
    ) {
        self.fileSystemState = fileSystemState
        self.diskImagePresent = diskImagePresent
        self.timeMachineMountPoint = timeMachineMountPoint
        self.deviceIdentifier = deviceIdentifier
        self.hasBackupRole = hasBackupRole
        self.matchingDestinationIdentifier = matchingDestinationIdentifier
        self.knownDestinationIdentifiers = knownDestinationIdentifiers
    }

    public static let unknown = TimeMachineSystemDiskObservation(
        fileSystemState: .unknown,
        diskImagePresent: false,
        timeMachineMountPoint: nil,
        deviceIdentifier: nil,
        hasBackupRole: false,
        matchingDestinationIdentifier: nil,
        knownDestinationIdentifiers: []
    )

    public var isCompletelyAbsent: Bool {
        fileSystemState == .unmounted
            && !diskImagePresent
            && timeMachineMountPoint == nil
            && deviceIdentifier == nil
            && matchingDestinationIdentifier == nil
    }

    public func connectedResult(
        expectedDestinationIdentifier: String?
    ) -> TimeMachineSetupResult? {
        guard
            fileSystemState == .mounted,
            diskImagePresent,
            hasBackupRole,
            let timeMachineMountPoint,
            let deviceIdentifier,
            let matchingDestinationIdentifier,
            let canonicalMatching = UUID(
                uuidString: matchingDestinationIdentifier
            )?.uuidString
        else {
            return nil
        }
        if let expectedDestinationIdentifier {
            guard
                let canonicalExpected = UUID(
                    uuidString: expectedDestinationIdentifier
                )?.uuidString,
                canonicalExpected == canonicalMatching
            else {
                return nil
            }
        }
        return TimeMachineSetupResult(
            timeMachineMountPoint: timeMachineMountPoint,
            deviceIdentifier: deviceIdentifier,
            timeMachineDestinationID: canonicalMatching
        )
    }
}

public protocol TimeMachineUserDiskControlling: Sendable {
    func connect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        encryptionPassword: Data
    ) throws -> TimeMachineSetupResult

    func disconnect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws

    func observe(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws -> TimeMachineSystemDiskObservation
}

/// FSKit modules are approved and discovered in the signed-in user's session.
/// This controller deliberately keeps FSKit and DiskImages work in that same
/// unprivileged session. The privileged helper validates the resulting APFS
/// disk and owns only macOS Time Machine destination configuration.
public struct TimeMachineUserDiskController: TimeMachineUserDiskControlling, Sendable {
    private struct MountedFileSystem {
        var source: String
        var type: String
    }

    private enum ControllerError: Error, LocalizedError {
        case invalidSource
        case commandFailed(String)
        case operationTimedOut
        case missingAttachedVolume
        case missingBackupRole

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                "Delta's private Time Machine file-system mount failed its ownership or identity check."
            case let .commandFailed(message):
                message
            case .operationTimedOut:
                "Delta's Time Machine disk operation exceeded its safety deadline."
            case .missingAttachedVolume:
                "macOS attached the Time Machine disk image without returning a mounted APFS volume."
            case .missingBackupRole:
                "macOS did not retain the Backup role on Delta's Time Machine APFS volume. The disk was not added to Time Machine."
            }
        }
    }

    public var runner: any TimeMachineBinaryProcessRunning
    public var applicationSupportURL: URL?

    public init(
        runner: any TimeMachineBinaryProcessRunning = TimeMachineBinaryProcessRunner(),
        applicationSupportURL: URL? = nil
    ) {
        self.runner = runner
        self.applicationSupportURL = applicationSupportURL
    }

    public func connect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        encryptionPassword: Data
    ) throws -> TimeMachineSetupResult {
        let mountPoint = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            mountSessionID: mountSessionID,
            applicationSupportURL: applicationSupportURL
        )
        do {
            if let mountSessionID {
                let source = try TimeMachineRuntimePaths.sourceDirectory(
                    repositoryID: repositoryID,
                    applicationSupportURL: applicationSupportURL
                )
                try TimeMachineRuntimePaths.validateSourceDirectory(
                    source,
                    repositoryID: repositoryID,
                    expectedOwnerID: geteuid()
                )
                try TimeMachineRuntimePaths.removeStaleFileSystemMountPoints(
                    repositoryID: repositoryID,
                    keeping: mountSessionID,
                    applicationSupportURL: applicationSupportURL
                )
                try TimeMachineRuntimePaths.prepareMountSession(
                    repositoryID: repositoryID,
                    mountSessionID: mountSessionID,
                    applicationSupportURL: applicationSupportURL
                )
            }
            return try connectDisk(
                repositoryID: repositoryID,
                mountSessionID: mountSessionID,
                settings: settings,
                encryptionPassword: encryptionPassword,
                mountPoint: mountPoint
            )
        } catch {
            throw TimeMachineUserDiskControllerError.operationFailed(
                message: SensitiveLogRedactor.redact(error.localizedDescription),
                fileSystemState: fileSystemState(at: mountPoint)
            )
        }
    }

    public func disconnect(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws {
        let mountPoint = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            mountSessionID: mountSessionID,
            applicationSupportURL: applicationSupportURL
        )
        do {
            try disconnectDisk(
                repositoryID: repositoryID,
                settings: settings,
                mountPoint: mountPoint
            )
        } catch {
            throw TimeMachineUserDiskControllerError.operationFailed(
                message: SensitiveLogRedactor.redact(error.localizedDescription),
                fileSystemState: fileSystemState(at: mountPoint)
            )
        }
    }

    /// Reads the public mount, DiskImages, APFS, and Time Machine destination
    /// surfaces without changing any of them. A persisted lifecycle is never
    /// sufficient evidence that the system disk is still connected.
    public func observe(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings
    ) throws -> TimeMachineSystemDiskObservation {
        let mountPoint = try TimeMachineRuntimePaths.fileSystemMountPoint(
            repositoryID: repositoryID,
            mountSessionID: mountSessionID,
            applicationSupportURL: applicationSupportURL
        )
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        let mounted = try mountedFileSystem(at: mountPoint)
        if let mounted {
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid(),
                expectedMountSessionID: mountSessionID
            )
            try validateMountedFileSystem(mounted, source: source)
        }

        let image = mountPoint.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            isDirectory: true
        )
        let imagePresent = if mounted != nil {
            try diskImageExists(at: image, mountedRoot: mountPoint)
        } else {
            false
        }
        let deadline = TimeMachineSetupDeadline(duration: 30)
        let home = try homeDirectory()
        let attached = try attachedVolumeIfPresent(
            for: image,
            home: home,
            deadline: deadline
        )
        let destinationResult = try run(
            executable: "/usr/bin/tmutil",
            arguments: ["destinationinfo", "-X"],
            home: home,
            deadline: deadline,
            maximumOutputBytes: 2 * 1_048_576
        )
        let destinationInformation = try TimeMachineDestinationInformationParser
            .parse(
                destinationResult.standardOutput,
                matchingMountPoint: attached?.mountPoint
            )
        let hasBackupRole = if let attached {
            try apfsVolumeHasBackupRole(
                deviceIdentifier: attached.deviceIdentifier,
                home: home,
                deadline: deadline
            )
        } else {
            false
        }
        return TimeMachineSystemDiskObservation(
            fileSystemState: mounted == nil ? .unmounted : .mounted,
            diskImagePresent: imagePresent,
            timeMachineMountPoint: attached?.mountPoint,
            deviceIdentifier: attached?.deviceIdentifier,
            hasBackupRole: hasBackupRole,
            matchingDestinationIdentifier: destinationInformation
                .matchingIdentifier,
            knownDestinationIdentifiers: destinationInformation.knownIdentifiers
        )
    }

    private func connectDisk(
        repositoryID: UUID,
        mountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        encryptionPassword: Data,
        mountPoint: URL
    ) throws -> TimeMachineSetupResult {
        guard
            !encryptionPassword.isEmpty,
            encryptionPassword.count <= TimeMachineSetupExecutionPolicy.maximumPasswordBytes
        else {
            throw ControllerError.invalidSource
        }
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        try TimeMachineRuntimePaths.validateSourceDirectory(
            source,
            repositoryID: repositoryID,
            expectedOwnerID: geteuid(),
            expectedMountSessionID: mountSessionID
        )

        let deadline = TimeMachineSetupDeadline(
            duration: TimeMachineSetupExecutionPolicy.operationRuntime
        )
        var mountedForAttempt = false
        var attachedForRollback: (deviceIdentifier: String, mountPoint: String)?
        var stagingImage: URL?
        do {
            if let mounted = try mountedFileSystem(at: mountPoint) {
                try validateMountedFileSystem(mounted, source: source)
                mountedForAttempt = true
            } else {
                try prepareMountPoint(mountPoint)
                try run(
                    executable: TimeMachineFSKitMountCommand.executable,
                    arguments: TimeMachineFSKitMountCommand.arguments(
                        sourcePath: source.path,
                        mountPoint: mountPoint.path
                    ),
                    home: try homeDirectory(),
                    deadline: deadline
                )
                guard let mounted = try mountedFileSystem(at: mountPoint) else {
                    throw ControllerError.invalidSource
                }
                try validateMountedFileSystem(mounted, source: source)
                mountedForAttempt = true
            }

            let image = mountPoint.appendingPathComponent(
                TimeMachineRuntimePaths.diskImageName(settings: settings),
                isDirectory: true
            )
            var passwordInput = encryptionPassword
            passwordInput.append(0x0A)
            defer { passwordInput.resetBytes(in: passwordInput.indices) }
            if try !diskImageExists(at: image, mountedRoot: mountPoint) {
                let staged = mountPoint.appendingPathComponent(
                    TimeMachineRuntimePaths.diskImageStagingName(settings: settings),
                    isDirectory: true
                )
                try TimeMachineRuntimePaths.removeDiskImageStagingDirectory(
                    settings: settings,
                    from: mountPoint
                )
                stagingImage = staged
                try run(
                    executable: "/usr/bin/hdiutil",
                    arguments: [
                        "create",
                        "-size", "\(settings.imageCapacityBytes)b",
                        "-type", "SPARSEBUNDLE",
                        "-fs", TimeMachineRepositorySettings.sparsebundleFileSystemName,
                        "-volname", settings.volumeName,
                        "-encryption", "AES-256",
                        "-stdinpass",
                        staged.path
                    ],
                    standardInput: passwordInput,
                    home: try homeDirectory(),
                    deadline: deadline
                )
                try TimeMachineRuntimePaths.promoteDiskImageStagingDirectory(
                    settings: settings,
                    in: mountPoint
                )
                stagingImage = nil
            }
            try TimeMachineRuntimePaths.secureDiskImageDirectory(
                settings: settings,
                in: mountPoint
            )

            let attached: (deviceIdentifier: String, mountPoint: String)
            if let existing = try attachedVolumeIfPresent(
                for: image,
                home: try homeDirectory(),
                deadline: deadline
            ) {
                attached = existing
            } else {
                let result = try run(
                    executable: "/usr/bin/hdiutil",
                    arguments: [
                        "attach",
                        "-stdinpass",
                        "-nobrowse",
                        "-owners", "on",
                        "-plist",
                        image.path
                    ],
                    standardInput: passwordInput,
                    home: try homeDirectory(),
                    deadline: deadline,
                    maximumOutputBytes: 2 * 1_048_576
                )
                attached = try attachedVolume(from: result.standardOutput)
            }
            attachedForRollback = attached
            try validateAttachedVolume(attached)
            try run(
                executable: "/usr/sbin/diskutil",
                arguments: ["apfs", "changeVolumeRole", attached.deviceIdentifier, "T"],
                home: try homeDirectory(),
                deadline: deadline
            )
            try validateAttachedVolume(attached)
            guard try apfsVolumeHasBackupRole(
                deviceIdentifier: attached.deviceIdentifier,
                home: try homeDirectory(),
                deadline: deadline
            ) else {
                throw ControllerError.missingBackupRole
            }
            return TimeMachineSetupResult(
                fileSystemMountPoint: mountPoint.path,
                timeMachineMountPoint: attached.mountPoint,
                deviceIdentifier: attached.deviceIdentifier
            )
        } catch {
            let rollbackDeadline = TimeMachineSetupDeadline(
                duration: TimeMachineSetupExecutionPolicy.rollbackRuntime
            )
            if let attachedForRollback,
               (try? validateAttachedVolume(attachedForRollback)) != nil {
                _ = try? run(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", attachedForRollback.deviceIdentifier],
                    home: try homeDirectory(),
                    deadline: rollbackDeadline
                )
            }
            if stagingImage != nil {
                try? TimeMachineRuntimePaths.removeDiskImageStagingDirectory(
                    settings: settings,
                    from: mountPoint
                )
            }
            if mountedForAttempt {
                _ = try? run(
                    executable: "/sbin/umount",
                    arguments: [mountPoint.path],
                    home: try homeDirectory(),
                    deadline: rollbackDeadline
                )
            }
            if (try? mountedFileSystem(at: mountPoint)) == nil {
                try? removeEmptyMountPoint(mountPoint)
            }
            throw error
        }
    }

    private func disconnectDisk(
        repositoryID: UUID,
        settings: TimeMachineRepositorySettings,
        mountPoint: URL
    ) throws {
        let source = try TimeMachineRuntimePaths.sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        let deadline = TimeMachineSetupDeadline(
            duration: TimeMachineSetupExecutionPolicy.operationRuntime
        )
        let image = mountPoint.appendingPathComponent(
            TimeMachineRuntimePaths.diskImageName(settings: settings),
            isDirectory: true
        )
        if let attached = try attachedVolumeIfPresent(
            for: image,
            home: try homeDirectory(),
            deadline: deadline
        ) {
            try validateAttachedVolume(attached)
            try run(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", attached.deviceIdentifier],
                home: try homeDirectory(),
                deadline: deadline
            )
        }
        if let mounted = try mountedFileSystem(at: mountPoint) {
            try TimeMachineRuntimePaths.validateSourceDirectory(
                source,
                repositoryID: repositoryID,
                expectedOwnerID: geteuid()
            )
            try validateMountedFileSystem(mounted, source: source)
            try run(
                executable: "/sbin/umount",
                arguments: [mountPoint.path],
                home: try homeDirectory(),
                deadline: deadline
            )
            guard try mountedFileSystem(at: mountPoint) == nil else {
                throw ControllerError.invalidSource
            }
        }
        try removeEmptyMountPoint(mountPoint)
    }

    private func fileSystemState(at mountPoint: URL) -> TimeMachineFileSystemResidualState {
        do {
            return try mountedFileSystem(at: mountPoint) == nil ? .unmounted : .mounted
        } catch {
            return .unknown
        }
    }

    private func prepareMountPoint(_ mountPoint: URL) throws {
        let parent = mountPoint.deletingLastPathComponent()
        var parentAttributes = stat()
        guard
            lstat(parent.path, &parentAttributes) == 0,
            (parentAttributes.st_mode & S_IFMT) == S_IFDIR,
            parentAttributes.st_uid == geteuid(),
            (parentAttributes.st_mode & 0o022) == 0
        else {
            throw ControllerError.invalidSource
        }
        var attributes = stat()
        if lstat(mountPoint.path, &attributes) != 0 {
            guard errno == ENOENT else { throw ControllerError.invalidSource }
            try FileManager.default.createDirectory(
                at: mountPoint,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard
            lstat(mountPoint.path, &attributes) == 0,
            (attributes.st_mode & S_IFMT) == S_IFDIR,
            attributes.st_uid == geteuid(),
            (attributes.st_mode & 0o077) == 0,
            try FileManager.default.contentsOfDirectory(atPath: mountPoint.path).isEmpty
        else {
            throw ControllerError.invalidSource
        }
    }

    private func removeEmptyMountPoint(_ mountPoint: URL) throws {
        guard Darwin.rmdir(mountPoint.path) == 0 else {
            if errno == ENOENT { return }
            throw ControllerError.invalidSource
        }
    }

    private func mountedFileSystem(at mountPoint: URL) throws -> MountedFileSystem? {
        var attributes = stat()
        guard lstat(mountPoint.path, &attributes) == 0 else {
            if errno == ENOENT { return nil }
            throw ControllerError.invalidSource
        }
        guard (attributes.st_mode & S_IFMT) == S_IFDIR else {
            throw ControllerError.invalidSource
        }
        var fileSystem = statfs()
        guard statfs(mountPoint.path, &fileSystem) == 0 else {
            throw ControllerError.invalidSource
        }
        let actualMountPoint = cString(from: &fileSystem.f_mntonname)
        guard actualMountPoint == mountPoint.standardizedFileURL.path else {
            return nil
        }
        return MountedFileSystem(
            source: cString(from: &fileSystem.f_mntfromname),
            type: cString(from: &fileSystem.f_fstypename)
        )
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
            throw ControllerError.invalidSource
        }
    }

    private func diskImageExists(at image: URL, mountedRoot: URL) throws -> Bool {
        var rootAttributes = stat()
        guard
            lstat(mountedRoot.path, &rootAttributes) == 0,
            (rootAttributes.st_mode & S_IFMT) == S_IFDIR,
            rootAttributes.st_uid == geteuid(),
            (rootAttributes.st_mode & 0o022) == 0
        else {
            throw ControllerError.invalidSource
        }
        var imageAttributes = stat()
        guard lstat(image.path, &imageAttributes) == 0 else {
            if errno == ENOENT { return false }
            throw ControllerError.invalidSource
        }
        guard
            (imageAttributes.st_mode & S_IFMT) == S_IFDIR,
            imageAttributes.st_dev == rootAttributes.st_dev,
            imageAttributes.st_uid == geteuid(),
            (imageAttributes.st_mode & 0o022) == 0
        else {
            throw ControllerError.invalidSource
        }
        return true
    }

    private func attachedVolume(
        from plistData: Data
    ) throws -> (deviceIdentifier: String, mountPoint: String) {
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: plistData,
                format: nil
            ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let entity = entities.first(where: { $0["mount-point"] != nil }),
            let mountPoint = entity["mount-point"] as? String,
            let devicePath = entity["dev-entry"] as? String
        else {
            throw ControllerError.missingAttachedVolume
        }
        let attached = (
            deviceIdentifier: URL(fileURLWithPath: devicePath).lastPathComponent,
            mountPoint: mountPoint
        )
        guard
            URL(fileURLWithPath: devicePath).standardizedFileURL.path == devicePath,
            URL(fileURLWithPath: devicePath).deletingLastPathComponent().path == "/dev"
        else {
            throw ControllerError.missingAttachedVolume
        }
        try validateAttachedVolume(attached)
        return attached
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
            maximumOutputBytes: 4 * 1_048_576
        )
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: result.standardOutput,
                format: nil
            ) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else {
            throw ControllerError.missingAttachedVolume
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
            throw ControllerError.missingAttachedVolume
        }
        let attached = (
            deviceIdentifier: URL(fileURLWithPath: devicePath).lastPathComponent,
            mountPoint: mountPoint
        )
        guard
            URL(fileURLWithPath: devicePath).standardizedFileURL.path == devicePath,
            URL(fileURLWithPath: devicePath).deletingLastPathComponent().path == "/dev"
        else {
            throw ControllerError.missingAttachedVolume
        }
        try validateAttachedVolume(attached)
        return attached
    }

    private func validateAttachedVolume(
        _ attached: (deviceIdentifier: String, mountPoint: String)
    ) throws {
        let mountURL = URL(fileURLWithPath: attached.mountPoint, isDirectory: true)
        let devicePath = "/dev/\(attached.deviceIdentifier)"
        guard
            !attached.mountPoint.utf8.contains(0),
            !attached.deviceIdentifier.utf8.contains(0),
            mountURL.standardizedFileURL.path == attached.mountPoint,
            mountURL.deletingLastPathComponent().path == "/Volumes",
            isDiskVolumeIdentifier(attached.deviceIdentifier)
        else {
            throw ControllerError.missingAttachedVolume
        }
        var fileSystem = statfs()
        guard statfs(attached.mountPoint, &fileSystem) == 0 else {
            throw ControllerError.missingAttachedVolume
        }
        guard
            cString(from: &fileSystem.f_mntonname) == attached.mountPoint,
            cString(from: &fileSystem.f_mntfromname) == devicePath,
            cString(from: &fileSystem.f_fstypename) == "apfs"
        else {
            throw ControllerError.missingAttachedVolume
        }
    }

    private func apfsVolumeHasBackupRole(
        deviceIdentifier: String,
        home: URL,
        deadline: TimeMachineSetupDeadline
    ) throws -> Bool {
        let result = try run(
            executable: "/usr/sbin/diskutil",
            arguments: ["apfs", "list", "-plist"],
            home: home,
            deadline: deadline,
            maximumOutputBytes: 8 * 1_048_576
        )
        return try TimeMachineAPFSVolumeRoleParser.hasBackupRole(
            result.standardOutput,
            deviceIdentifier: deviceIdentifier
        )
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

    private func homeDirectory() throws -> URL {
        guard let record = getpwuid(geteuid()), let path = record.pointee.pw_dir else {
            throw ControllerError.invalidSource
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    @discardableResult
    private func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        home: URL,
        deadline: TimeMachineSetupDeadline,
        maximumOutputBytes: Int = 1_048_576
    ) throws -> TimeMachineBinaryProcessResult {
        let remainingRuntime = deadline.remainingTime()
        guard remainingRuntime > 0 else {
            throw ControllerError.operationTimedOut
        }
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/tmp"
            ],
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            maximumRuntime: remainingRuntime
        )
        guard result.exitCode == 0 else {
            let message = SensitiveLogRedactor.redact(result.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControllerError.commandFailed(
                message.isEmpty
                    ? "\(URL(fileURLWithPath: executable).lastPathComponent) failed with exit \(result.exitCode)."
                    : message
            )
        }
        return result
    }
}

public enum TimeMachineUserDiskControllerError: Error, Equatable, LocalizedError, Sendable {
    case operationFailed(
        message: String,
        fileSystemState: TimeMachineFileSystemResidualState
    )

    public var errorDescription: String? {
        guard case let .operationFailed(message, _) = self else { return nil }
        return message
    }

    public var fileSystemState: TimeMachineFileSystemResidualState {
        guard case let .operationFailed(_, state) = self else { return .unknown }
        return state
    }
}
