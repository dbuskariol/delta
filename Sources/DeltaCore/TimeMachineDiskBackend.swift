import Darwin
import DeltaTimeMachineIPC
import Foundation
import OSLog

public enum TimeMachineRuntimePathError: Error, LocalizedError, Equatable {
    case invalidSourceDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidSourceDirectory:
            "Delta's Time Machine source directory failed its ownership or path check."
        }
    }
}

/// A public FSKit `noowners` mount projects ownership as the effective user of
/// the observing process. Ownership is therefore authoritative only in the
/// private source namespace when that flag is set; every other mounted-view
/// metadata and identity check remains mandatory.
public enum TimeMachineMountedOwnershipPolicy {
    public static func accepts(
        observedOwnerID: uid_t,
        expectedOwnerID: uid_t,
        mountIgnoresOwnership: Bool
    ) -> Bool {
        mountIgnoresOwnership || observedOwnerID == expectedOwnerID
    }
}

public enum TimeMachineRuntimePaths {
    public static let repositoryMarkerFileName =
        DeltaTimeMachineFileSystemIdentity.repositoryMarkerFileName
    public static let mountSessionMarkerFileName =
        DeltaTimeMachineFileSystemIdentity.mountSessionMarkerFileName

    public static func writerIdentityURL(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        try repositoryDirectory(repositoryID: repositoryID, applicationSupportURL: applicationSupportURL)
            .appendingPathComponent("writer-identity", isDirectory: false)
    }

    public static func loadOrCreateWriterID(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> UUID {
        let directory = try repositoryDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("writer-identity", isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            return try readWriterID(at: url)
        }

        let writerID = UUID()
        let data = Data(writerID.uuidString.lowercased().utf8)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0, errno == EEXIST {
            return try readWriterID(at: url)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        var writeError: Error?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                    return
                }
                offset += count
            }
        }
        if writeError == nil, Darwin.fsync(descriptor) != 0 {
            writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        if Darwin.close(descriptor) != 0, writeError == nil {
            writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        if let writeError {
            try? FileManager.default.removeItem(at: url)
            throw writeError
        }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            _ = Darwin.close(directoryDescriptor)
        }
        return writerID
    }

    public static func repositoryDirectory(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let support = try applicationSupportURL ?? AppDirectories.applicationSupportDirectory()
        return support
            .appendingPathComponent("TimeMachine", isDirectory: true)
            .appendingPathComponent(repositoryID.uuidString, isDirectory: true)
    }

    public static func sourceDirectory(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        try repositoryDirectory(repositoryID: repositoryID, applicationSupportURL: applicationSupportURL)
            .appendingPathComponent("source", isDirectory: true)
    }

    public static func cacheDirectory(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        try repositoryDirectory(repositoryID: repositoryID, applicationSupportURL: applicationSupportURL)
            .appendingPathComponent("cache", isDirectory: true)
    }

    public static func socketURL(
        repositoryID: UUID,
        applicationGroupContainerURL: URL? = nil
    ) throws -> URL {
        try DeltaTimeMachineIPCIdentity.controlSocketURL(
            repositoryID: repositoryID,
            applicationGroupContainerURL: applicationGroupContainerURL
        )
    }

    public static func repositoryMarkerURL(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        try sourceDirectory(repositoryID: repositoryID, applicationSupportURL: applicationSupportURL)
            .appendingPathComponent(repositoryMarkerFileName)
    }

    /// Validates the exact private source directory and repository marker
    /// without following a substituted root or marker. The app, user-session
    /// disk controller, and privileged helper share this check before trusting
    /// an FSKit path resource.
    public static func validateSourceDirectory(
        _ directory: URL,
        repositoryID: UUID,
        expectedOwnerID: uid_t,
        expectedMountSessionID: UUID? = nil
    ) throws {
        let descriptor = Darwin.open(
            directory.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var root = stat()
        guard
            Darwin.fstat(descriptor, &root) == 0,
            (root.st_mode & S_IFMT) == S_IFDIR,
            root.st_uid == expectedOwnerID,
            (root.st_mode & 0o022) == 0
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        guard
            try readUUIDMarker(
                named: repositoryMarkerFileName,
                sourceDescriptor: descriptor,
                rootDevice: root.st_dev,
                expectedOwnerID: expectedOwnerID
            ) == repositoryID
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        if let expectedMountSessionID {
            guard
                try readUUIDMarker(
                    named: mountSessionMarkerFileName,
                    sourceDescriptor: descriptor,
                    rootDevice: root.st_dev,
                    expectedOwnerID: expectedOwnerID
                ) == expectedMountSessionID
            else {
                throw TimeMachineRuntimePathError.invalidSourceDirectory
            }
        }
        var finalRoot = stat()
        guard
            Darwin.lstat(directory.standardizedFileURL.path, &finalRoot) == 0,
            (finalRoot.st_mode & S_IFMT) == S_IFDIR,
            finalRoot.st_dev == root.st_dev,
            finalRoot.st_ino == root.st_ino,
            finalRoot.st_uid == root.st_uid
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
    }

    /// Publishes the exact connection qualifier that FSKit probes and loads.
    /// The marker is private, no-follow, single-link, atomically replaced, and
    /// durably synchronized before `mount(8)` can observe it.
    public static func prepareMountSession(
        repositoryID: UUID,
        mountSessionID: UUID,
        applicationSupportURL: URL? = nil,
        expectedOwnerID: uid_t = geteuid()
    ) throws {
        let source = try sourceDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        try validateSourceDirectory(
            source,
            repositoryID: repositoryID,
            expectedOwnerID: expectedOwnerID
        )
        let descriptor = Darwin.open(
            source.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(descriptor) }
        var root = stat()
        guard
            Darwin.fstat(descriptor, &root) == 0,
            (root.st_mode & S_IFMT) == S_IFDIR,
            root.st_uid == expectedOwnerID,
            (root.st_mode & 0o022) == 0,
            try readUUIDMarker(
                named: repositoryMarkerFileName,
                sourceDescriptor: descriptor,
                rootDevice: root.st_dev,
                expectedOwnerID: expectedOwnerID
            ) == repositoryID
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        try writePrivateMarker(
            named: mountSessionMarkerFileName,
            value: mountSessionID,
            sourceDescriptor: descriptor
        )
        try validateSourceDirectory(
            source,
            repositoryID: repositoryID,
            expectedOwnerID: expectedOwnerID,
            expectedMountSessionID: mountSessionID
        )
    }

    static func readUUIDMarker(
        named name: String,
        sourceDescriptor: Int32,
        rootDevice: dev_t,
        expectedOwnerID: uid_t
    ) throws -> UUID {
        let marker = Darwin.openat(
            sourceDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard marker >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(marker) }
        var markerStatus = stat()
        guard
            Darwin.fstat(marker, &markerStatus) == 0,
            (markerStatus.st_mode & S_IFMT) == S_IFREG,
            markerStatus.st_uid == expectedOwnerID,
            markerStatus.st_dev == rootDevice,
            markerStatus.st_nlink == 1,
            (markerStatus.st_mode & 0o077) == 0,
            markerStatus.st_size > 0,
            markerStatus.st_size <= 128,
            let markerSize = Int(exactly: markerStatus.st_size)
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        var data = Data(count: markerSize)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw TimeMachineRuntimePathError.invalidSourceDirectory
            }
            while offset < markerSize {
                let count = Darwin.read(
                    marker,
                    base.advanced(by: offset),
                    markerSize - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TimeMachineRuntimePathError.invalidSourceDirectory
                }
                offset += count
            }
        }
        guard
            let markerText = String(data: data, encoding: .utf8),
            let value = UUID(
                uuidString: markerText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        return value
    }

    static func writePrivateMarker(
        named name: String,
        value: UUID,
        sourceDescriptor: Int32
    ) throws {
        let stagedName = "\(name).\(UUID().uuidString.lowercased())"
        let descriptor = Darwin.openat(
            sourceDescriptor,
            stagedName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.unlinkat(sourceDescriptor, stagedName, 0) }
        let data = Data(value.uuidString.utf8)
        var writeError: Error?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                    return
                }
                offset += count
            }
        }
        if writeError == nil, Darwin.fsync(descriptor) != 0 {
            writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        if Darwin.close(descriptor) != 0, writeError == nil {
            writeError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        if let writeError { throw writeError }
        guard Darwin.renameat(
            sourceDescriptor,
            stagedName,
            sourceDescriptor,
            name
        ) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(sourceDescriptor) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    public static func diskImageName(settings: TimeMachineRepositorySettings) -> String {
        "\(settings.storeID.uuidString.lowercased()).sparsebundle"
    }

    /// This name intentionally does not use Delta's `.delta-` control prefix:
    /// FSKit keeps control-prefixed items local, while image creation must stream
    /// through the remote object backend. The user-session disk controller promotes this
    /// staging bundle only after `hdiutil create` succeeds.
    public static func diskImageStagingName(settings: TimeMachineRepositorySettings) -> String {
        "\(settings.storeID.uuidString.lowercased()).creating.sparsebundle"
    }

    public static func diskImageRelativePath(settings: TimeMachineRepositorySettings) -> String {
        diskImageName(settings: settings)
    }

    /// Verifies the real source-side sparsebundle directory rather than the
    /// ownership-projected FSKit mount. A `noowners` mount reports objects as
    /// owned by the observing process, so a privileged observer must anchor
    /// ownership and permissions in this private backing namespace instead.
    public static func sourceDiskImageExists(
        sourceDirectory: URL,
        repositoryID: UUID,
        expectedMountSessionID: UUID?,
        settings: TimeMachineRepositorySettings,
        expectedOwnerID: uid_t
    ) throws -> Bool {
        let sourceDescriptor = Darwin.open(
            sourceDirectory.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(sourceDescriptor) }
        var root = stat()
        guard
            Darwin.fstat(sourceDescriptor, &root) == 0,
            (root.st_mode & S_IFMT) == S_IFDIR,
            root.st_uid == expectedOwnerID,
            (root.st_mode & 0o077) == 0,
            try readUUIDMarker(
                named: repositoryMarkerFileName,
                sourceDescriptor: sourceDescriptor,
                rootDevice: root.st_dev,
                expectedOwnerID: expectedOwnerID
            ) == repositoryID
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        if let expectedMountSessionID {
            guard
                try readUUIDMarker(
                    named: mountSessionMarkerFileName,
                    sourceDescriptor: sourceDescriptor,
                    rootDevice: root.st_dev,
                    expectedOwnerID: expectedOwnerID
                ) == expectedMountSessionID
            else {
                throw TimeMachineRuntimePathError.invalidSourceDirectory
            }
        }
        var image = stat()
        let imageLookup = Darwin.fstatat(
            sourceDescriptor,
            diskImageName(settings: settings),
            &image,
            AT_SYMLINK_NOFOLLOW
        )
        let imageMissing = imageLookup != 0 && errno == ENOENT
        guard imageLookup == 0 || imageMissing else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        if !imageMissing {
            guard
                (image.st_mode & S_IFMT) == S_IFDIR,
                image.st_dev == root.st_dev,
                image.st_uid == expectedOwnerID,
                (image.st_mode & 0o077) == 0
            else {
                throw TimeMachineRuntimePathError.invalidSourceDirectory
            }
        }
        var finalRoot = stat()
        guard
            Darwin.lstat(sourceDirectory.standardizedFileURL.path, &finalRoot) == 0,
            (finalRoot.st_mode & S_IFMT) == S_IFDIR,
            finalRoot.st_dev == root.st_dev,
            finalRoot.st_ino == root.st_ino,
            finalRoot.st_uid == root.st_uid
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        return !imageMissing
    }

    /// The FSKit mount is an implementation detail rather than the visible
    /// Time Machine disk. FSKit modules are enabled per signed-in user, so the
    /// owning user session mounts this private directory; only the APFS volume
    /// attached by DiskImages is exposed below `/Volumes`. Keeping the mount in
    /// repository-scoped Application Support also prevents two repositories
    /// with the same UUID prefix from sharing a mount point.
    public static func fileSystemMountPoint(
        repositoryID: UUID,
        mountSessionID: UUID? = nil,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        try repositoryDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        ).appendingPathComponent(
            mountSessionID.map {
                "filesystem-\($0.uuidString.lowercased())"
            } ?? "filesystem",
            isDirectory: true
        )
    }

    /// Reclaims only empty, unmounted mount-instance directories owned by the
    /// current user. FSKit records mount points by path, so each connection has
    /// a persisted session identity and a crashed instance cannot prevent a
    /// later connection. No recursive removal or symlink following is used.
    public static func removeStaleFileSystemMountPoints(
        repositoryID: UUID,
        keeping mountSessionID: UUID,
        applicationSupportURL: URL? = nil,
        expectedOwnerID: uid_t = geteuid()
    ) throws {
        let repository = try repositoryDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        let repositoryDescriptor = try openVerifiedRuntimeRoot(
            repository,
            expectedOwnerID: expectedOwnerID
        )
        defer { _ = Darwin.close(repositoryDescriptor) }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: repository.path
        )
        guard names.count <= 1_024 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        let retainedName = "filesystem-\(mountSessionID.uuidString.lowercased())"
        for name in names where name != retainedName && isFileSystemMountPointName(name) {
            var attributes = stat()
            guard
                Darwin.fstatat(
                    repositoryDescriptor,
                    name,
                    &attributes,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                (attributes.st_mode & S_IFMT) == S_IFDIR,
                attributes.st_uid == expectedOwnerID,
                (attributes.st_mode & 0o077) == 0
            else {
                continue
            }
            if Darwin.unlinkat(repositoryDescriptor, name, AT_REMOVEDIR) != 0,
               errno != ENOTEMPTY,
               errno != EBUSY {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func isFileSystemMountPointName(_ name: String) -> Bool {
        if name == "filesystem" { return true }
        let prefix = "filesystem-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix.lowercased()
    }

    public static func mountPoint(repositoryID: UUID, volumeName: String) -> URL {
        let safeName = volumeName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: "/Volumes/\(safeName)-\(repositoryID.uuidString.prefix(8))", isDirectory: true)
    }

    /// Removes only the canonical, reconstructible image-creation directory.
    /// Traversal is descriptor-relative and never follows a symlink, which is
    /// required because DiskImages and FSKit share this user-owned mount.
    public static func removeDiskImageStagingDirectory(
        settings: TimeMachineRepositorySettings,
        from root: URL,
        expectedOwnerID: uid_t = geteuid()
    ) throws {
        let rootDescriptor = try openVerifiedRuntimeRoot(
            root,
            expectedOwnerID: expectedOwnerID
        )
        defer { _ = Darwin.close(rootDescriptor) }
        var rootAttributes = stat()
        guard Darwin.fstat(rootDescriptor, &rootAttributes) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        let name = diskImageStagingName(settings: settings)
        var attributes = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            name,
            &attributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        try TimeMachineDescriptorTree.remove(
            parentDescriptor: rootDescriptor,
            name: name,
            expectedAttributes: attributes,
            rootDevice: rootAttributes.st_dev,
            expectedOwnerID: expectedOwnerID
        )
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    /// Atomically promotes the canonical staging directory without allowing a
    /// competing path replacement to overwrite an existing disk image.
    public static func promoteDiskImageStagingDirectory(
        settings: TimeMachineRepositorySettings,
        in root: URL,
        expectedOwnerID: uid_t = geteuid()
    ) throws {
        let rootDescriptor = try openVerifiedRuntimeRoot(
            root,
            expectedOwnerID: expectedOwnerID
        )
        defer { _ = Darwin.close(rootDescriptor) }
        var rootAttributes = stat()
        guard Darwin.fstat(rootDescriptor, &rootAttributes) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        let stagingName = diskImageStagingName(settings: settings)
        var stagingAttributes = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            stagingName,
            &stagingAttributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard
            (stagingAttributes.st_mode & S_IFMT) == S_IFDIR,
            stagingAttributes.st_dev == rootAttributes.st_dev,
            stagingAttributes.st_uid == expectedOwnerID,
            (stagingAttributes.st_mode & 0o022) == 0
        else {
            throw POSIXError(.EPERM)
        }
        let finalName = diskImageName(settings: settings)
        guard Darwin.renameatx_np(
            rootDescriptor,
            stagingName,
            rootDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        try secureDiskImageDirectory(
            settings: settings,
            in: root,
            expectedOwnerID: expectedOwnerID
        )
    }

    /// Makes the outer sparsebundle directory private through a verified,
    /// descriptor-relative handle. `hdiutil create` may use the process umask
    /// and leave this directory world-readable; the privileged setup helper
    /// deliberately rejects that mode before changing global Time Machine
    /// configuration.
    public static func secureDiskImageDirectory(
        settings: TimeMachineRepositorySettings,
        in root: URL,
        expectedOwnerID: uid_t = geteuid()
    ) throws {
        let rootDescriptor = try openVerifiedRuntimeRoot(
            root,
            expectedOwnerID: expectedOwnerID
        )
        defer { _ = Darwin.close(rootDescriptor) }
        let imageDescriptor = Darwin.openat(
            rootDescriptor,
            diskImageName(settings: settings),
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard imageDescriptor >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(imageDescriptor) }
        var rootStatus = stat()
        var imageStatus = stat()
        guard
            Darwin.fstat(rootDescriptor, &rootStatus) == 0,
            Darwin.fstat(imageDescriptor, &imageStatus) == 0,
            (imageStatus.st_mode & S_IFMT) == S_IFDIR,
            imageStatus.st_dev == rootStatus.st_dev,
            imageStatus.st_uid == expectedOwnerID,
            Darwin.fchmod(imageDescriptor, S_IRWXU) == 0,
            Darwin.fsync(imageDescriptor) == 0,
            Darwin.fstat(imageDescriptor, &imageStatus) == 0,
            (imageStatus.st_mode & 0o777) == S_IRWXU,
            Darwin.fsync(rootDescriptor) == 0
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
    }

    /// Deletes only reconstructible local Time Machine runtime state after the
    /// system disk and storage service are disconnected. Remote objects and
    /// Keychain recovery material are outside this directory.
    public static func removeLocalState(
        repositoryID: UUID,
        applicationSupportURL: URL? = nil
    ) throws {
        let directory = try repositoryDirectory(
            repositoryID: repositoryID,
            applicationSupportURL: applicationSupportURL
        )
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard
            (attributes.st_mode & S_IFMT) == S_IFDIR,
            attributes.st_uid == geteuid()
        else {
            throw POSIXError(.EPERM)
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func readWriterID(at url: URL) throws -> UUID {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            (status.st_mode & 0o077) == 0,
            status.st_size > 0,
            status.st_size <= 128
        else {
            throw POSIXError(.EPERM)
        }
        var data = Data(count: Int(status.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < bytes.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard let writerID = UUID(
            uuidString: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw POSIXError(.EINVAL)
        }
        return writerID
    }

    private static func openVerifiedRuntimeRoot(
        _ root: URL,
        expectedOwnerID: uid_t
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            root.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        var attributes = stat()
        guard
            Darwin.fstat(descriptor, &attributes) == 0,
            (attributes.st_mode & S_IFMT) == S_IFDIR,
            attributes.st_uid == expectedOwnerID,
            (attributes.st_mode & 0o022) == 0
        else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        return descriptor
    }
}

/// Shared no-follow traversal for placeholder reconciliation and privileged
/// staging cleanup. Each entry is rebound to its original device, inode, type,
/// and owner immediately before removal so a concurrent namespace replacement
/// fails closed instead of redirecting traversal.
private enum TimeMachineDescriptorTree {
    static func entryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let openError = errno
            _ = Darwin.close(duplicate)
            throw POSIXError(POSIXError.Code(rawValue: openError) ?? .EIO)
        }
        defer { _ = Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            var rawName = entry.pointee.d_name
            let rawNameCapacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: rawNameCapacity
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        return names
    }

    static func remove(
        parentDescriptor: Int32,
        name: String,
        expectedAttributes: stat,
        rootDevice: dev_t,
        expectedOwnerID: uid_t
    ) throws {
        guard
            expectedAttributes.st_dev == rootDevice,
            expectedAttributes.st_uid == expectedOwnerID
        else {
            throw POSIXError(.EPERM)
        }
        if (expectedAttributes.st_mode & S_IFMT) == S_IFDIR {
            let child = try openVerifiedDirectory(
                parentDescriptor: parentDescriptor,
                name: name,
                expectedAttributes: expectedAttributes,
                rootDevice: rootDevice,
                expectedOwnerID: expectedOwnerID
            )
            defer { _ = Darwin.close(child) }
            for childName in try entryNames(descriptor: child) {
                var childAttributes = stat()
                guard Darwin.fstatat(
                    child,
                    childName,
                    &childAttributes,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                try remove(
                    parentDescriptor: child,
                    name: childName,
                    expectedAttributes: childAttributes,
                    rootDevice: rootDevice,
                    expectedOwnerID: expectedOwnerID
                )
            }
            try verifyEntry(
                parentDescriptor: parentDescriptor,
                name: name,
                expectedAttributes: expectedAttributes,
                rootDevice: rootDevice,
                expectedOwnerID: expectedOwnerID
            )
            guard Darwin.unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            return
        }
        try verifyEntry(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedAttributes: expectedAttributes,
            rootDevice: rootDevice,
            expectedOwnerID: expectedOwnerID
        )
        guard Darwin.unlinkat(parentDescriptor, name, 0) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    static func openVerifiedDirectory(
        parentDescriptor: Int32,
        name: String,
        expectedAttributes: stat,
        rootDevice: dev_t,
        expectedOwnerID: uid_t
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        var current = stat()
        guard
            Darwin.fstat(descriptor, &current) == 0,
            (current.st_mode & S_IFMT) == S_IFDIR,
            current.st_dev == expectedAttributes.st_dev,
            current.st_ino == expectedAttributes.st_ino,
            current.st_dev == rootDevice,
            current.st_uid == expectedOwnerID,
            (current.st_mode & 0o022) == 0
        else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        return descriptor
    }

    private static func verifyEntry(
        parentDescriptor: Int32,
        name: String,
        expectedAttributes: stat,
        rootDevice: dev_t,
        expectedOwnerID: uid_t
    ) throws {
        var current = stat()
        guard
            Darwin.fstatat(
                parentDescriptor,
                name,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            current.st_dev == expectedAttributes.st_dev,
            current.st_ino == expectedAttributes.st_ino,
            (current.st_mode & S_IFMT) == (expectedAttributes.st_mode & S_IFMT),
            current.st_dev == rootDevice,
            current.st_uid == expectedOwnerID
        else {
            throw POSIXError(.EPERM)
        }
    }
}

public final class TimeMachineDiskBackend: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.delta.backup",
        category: "TimeMachineDiskBackend"
    )
    private let lock = NSRecursiveLock()
    private let leaseLock = NSLock()
    private let synchronizationStateLock = NSLock()
    private let synchronizationQueue: DispatchQueue
    private let repository: BackupRepository
    private let settings: TimeMachineRepositorySettings
    private let database: DeltaDatabase
    private let store: TimeMachineGenerationStore
    private let session: TimeMachineSparseFileSession
    private let sourceDirectory: URL
    private let controlSocketURL: URL
    private let localJobLock: RepositoryJobLock
    private let writerID: UUID
    private var head: TimeMachineGenerationHead
    private var lease: TimeMachineRemoteLease
    private var leaseTimer: DispatchSourceTimer?
    private var terminalLeaseError: Error?
    private var asynchronousSynchronizationIsScheduled = false
    private var asynchronousSynchronizationNeedsAnotherPass = false

    public init(
        repository: BackupRepository,
        database: DeltaDatabase,
        authenticationKey: Data,
        transport: AnyTimeMachineRemoteObjectTransport,
        applicationSupportURL: URL? = nil,
        applicationGroupContainerURL: URL? = nil
    ) throws {
        guard repository.format == .timeMachine else {
            throw TimeMachineDestinationManagerError.notTimeMachineDestination
        }
        guard let settings = repository.timeMachineSettings else {
            throw TimeMachineDestinationManagerError.missingSettings
        }
        self.repository = repository
        self.settings = settings
        self.database = database
        self.synchronizationQueue = DispatchQueue(
            label: "com.delta.backup.timemachine.synchronize.\(repository.id.uuidString.lowercased())",
            qos: .utility
        )
        guard let localJobLock = try RepositoryJobLockManager().acquire(repositoryID: repository.id) else {
            throw TimeMachineDestinationManagerError.destinationBusy
        }
        self.localJobLock = localJobLock
        let generationStore = try TimeMachineGenerationStore(
            namespace: settings.remoteNamespace,
            storeID: settings.storeID,
            authenticationKey: authenticationKey,
            transport: transport
        )
        let authenticatedHistory = try generationStore.loadValidatedManifestHistory()
        guard let preflightHead = authenticatedHistory.last else {
            throw TimeMachineObjectStoreError.objectNotFound("\(settings.remoteNamespace)/manifests")
        }
        let persistedState = try database.fetchTimeMachineDestinationState(
            repositoryID: repository.id
        )
        try TimeMachineGenerationContinuityPolicy.validate(
            remoteHistory: authenticatedHistory,
            persistedState: persistedState,
            expectedStoreID: settings.storeID
        )
        let preflightFiles = try generationStore.loadFiles(from: preflightHead)

        let runtimeWriterID = try TimeMachineRuntimePaths.loadOrCreateWriterID(
            repositoryID: repository.id,
            applicationSupportURL: applicationSupportURL
        )
        let acquiredLease = try generationStore.acquireLease(
            ownerID: runtimeWriterID,
            duration: 300
        )
        do {
            // A remote writer may have committed between the read-only
            // preflight and lease acquisition. Re-authenticate under the lease
            // before creating placeholders or touching the bounded cache.
            let leasedHistory = try generationStore.loadValidatedManifestHistory()
            try TimeMachineGenerationContinuityPolicy.validate(
                remoteHistory: leasedHistory,
                persistedState: persistedState,
                expectedStoreID: settings.storeID
            )
            guard let leasedHead = leasedHistory.last else {
                throw TimeMachineObjectStoreError.objectNotFound(
                    "\(settings.remoteNamespace)/manifests"
                )
            }
            let leasedFiles = leasedHead.signedManifest.manifestDigest
                == preflightHead.signedManifest.manifestDigest
                ? preflightFiles
                : try generationStore.loadFiles(from: leasedHead)
            let resolvedSourceDirectory = try TimeMachineRuntimePaths.sourceDirectory(
                repositoryID: repository.id,
                applicationSupportURL: applicationSupportURL
            )
            let resolvedControlSocketURL = try TimeMachineRuntimePaths.socketURL(
                repositoryID: repository.id,
                applicationGroupContainerURL: applicationGroupContainerURL
            )
            try Self.materializeSparsePlaceholders(
                files: leasedFiles,
                sourceDirectory: resolvedSourceDirectory,
                repositoryID: repository.id
            )
            let resolvedSession = try TimeMachineSparseFileSession(
                cacheURL: try TimeMachineRuntimePaths.cacheDirectory(
                    repositoryID: repository.id,
                    applicationSupportURL: applicationSupportURL
                ),
                storeID: settings.storeID,
                writerID: runtimeWriterID,
                cacheLimitBytes: settings.cacheLimitBytes,
                head: leasedHead,
                remoteFiles: leasedFiles
            )
            try TimeMachineRuntimePaths.validateSourceDirectory(
                resolvedSourceDirectory,
                repositoryID: repository.id,
                expectedOwnerID: geteuid()
            )

            self.writerID = runtimeWriterID
            self.store = generationStore
            self.head = leasedHead
            self.sourceDirectory = resolvedSourceDirectory
            self.controlSocketURL = resolvedControlSocketURL
            self.session = resolvedSession
            self.lease = acquiredLease
            self.leaseTimer = nil
            self.terminalLeaseError = nil
            self.asynchronousSynchronizationIsScheduled = false
            self.asynchronousSynchronizationNeedsAnotherPass = false
            try publishState(lifecycle: nil)
        } catch {
            try? generationStore.releaseLease(acquiredLease)
            throw error
        }
        startLeaseRenewalTimer()
    }

    deinit {
        leaseTimer?.setEventHandler {}
        leaseTimer?.cancel()
        leaseLock.lock()
        try? store.releaseLease(lease)
        leaseLock.unlock()
    }

    public func handle(
        request: TimeMachineDiskRequest,
        payload: Data
    ) -> TimeMachineDiskProtocolResult {
        if request.operation == .synchronize, request.wait != true {
            // FSSyncFlags.noWait requires I/O to start without waiting for it.
            // Enqueue onto a per-destination serial queue and return before any
            // remote transport work. The queued blocking path retains dirty
            // chunks on failure and publishes the error for explicit recovery.
            enqueueAsynchronousSynchronization()
            return TimeMachineDiskProtocolResult(response: TimeMachineDiskResponse())
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            switch request.operation {
            case .read:
                let path = try requiredPath(request.path)
                let offset = try requiredOffset(request.offset)
                guard let length = request.length, length >= 0 else {
                    throw TimeMachineSparseFileSessionError.invalidRange
                }
                let data = try session.read(
                    path: path,
                    offset: offset,
                    length: length,
                    reusingRemoteLoader: { reference, buffer in
                        try store.readChunk(reference, into: &buffer)
                    }
                )
                reportCacheWarningIfNeeded()
                return success(payload: data)

            case .write:
                try ensureWriterLease()
                let path = try requiredPath(request.path)
                let offset = try requiredOffset(request.offset)
                guard request.payloadLength == payload.count else {
                    throw TimeMachineDiskProtocolError.invalidFrame
                }
                try performWithRemoteSpillOnCachePressure {
                    try session.write(
                        path: path,
                        offset: offset,
                        data: payload,
                        reusingRemoteLoader: { reference, buffer in
                            try store.readChunk(reference, into: &buffer)
                        }
                    )
                }
                return success()

            case .create:
                try ensureWriterLease()
                let path = try requiredPath(request.path)
                try performWithRemoteSpillOnCachePressure {
                    try session.truncate(
                        path: path,
                        size: request.offset ?? 0,
                        reusingRemoteLoader: { reference, buffer in
                            try store.readChunk(reference, into: &buffer)
                        }
                    )
                }
                return success()

            case .truncate:
                try ensureWriterLease()
                let path = try requiredPath(request.path)
                let size = try requiredOffset(request.offset)
                try performWithRemoteSpillOnCachePressure {
                    try session.truncate(
                        path: path,
                        size: size,
                        reusingRemoteLoader: { reference, buffer in
                            try store.readChunk(reference, into: &buffer)
                        }
                    )
                }
                return success()

            case .remove:
                try ensureWriterLease()
                try session.remove(path: try requiredPath(request.path))
                return success()

            case .rename:
                try ensureWriterLease()
                try session.rename(
                    path: try requiredPath(request.path),
                    to: try requiredPath(request.destinationPath)
                )
                return success()

            case .synchronize:
                try ensureWriterLease()
                var committedHeadForPruning: TimeMachineGenerationHead?
                if let commit = try session.prepareCommit() {
                    let committed = try store.commit(commit, lease: currentLease())
                    let reconciliation = try session.acceptCommittedHead(committed)
                    head = committed
                    committedHeadForPruning = committed
                    if reconciliation == .cacheCleanupDeferred {
                        recordOperationalWarning(
                            "Time Machine generation \(committed.signedManifest.manifest.generation) is durable remotely, but reconstructible local cache cleanup was deferred."
                        )
                    }
                }
                var localWitnessWasSaved = false
                do {
                    try publishState(lifecycle: nil)
                    localWitnessWasSaved = true
                } catch {
                    // Remote fsync semantics are governed by the authenticated
                    // generation above. A local audit-state write failure must
                    // remain visible without asking DiskImages to republish an
                    // already-committed generation.
                    recordOperationalWarning(
                        "Time Machine storage is durable, but Delta could not update local destination state: \(SensitiveLogRedactor.redact(error.localizedDescription))"
                    )
                }
                if
                    localWitnessWasSaved,
                    let committed = committedHeadForPruning,
                    committed.signedManifest.manifest.generation > 256,
                    committed.signedManifest.manifest.generation.isMultiple(of: 16)
                {
                    do {
                        try store.pruneManifestHistory(
                            keepingNewestGenerations: 256,
                            expectedHead: committed,
                            lease: currentLease()
                        )
                    } catch {
                        recordOperationalWarning(
                            "Time Machine storage is durable, but old transport manifests could not be compacted: \(SensitiveLogRedactor.redact(error.localizedDescription))"
                        )
                    }
                }
                return success()

            case .status:
                return success(includeStorageMetrics: true)
            }
        } catch {
            try? publishFailure(error)
            return TimeMachineDiskProtocolResult(
                response: TimeMachineDiskResponse(
                    repositoryID: repository.id,
                    errorNumber: Self.errorNumber(for: error),
                    message: SensitiveLogRedactor.redact(error.localizedDescription)
                )
            )
        }
    }

    public var socketPath: String {
        controlSocketURL.path
    }

    private func enqueueAsynchronousSynchronization() {
        synchronizationStateLock.lock()
        asynchronousSynchronizationNeedsAnotherPass = true
        guard !asynchronousSynchronizationIsScheduled else {
            synchronizationStateLock.unlock()
            return
        }
        asynchronousSynchronizationIsScheduled = true
        synchronizationStateLock.unlock()

        synchronizationQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.synchronizationStateLock.lock()
                self.asynchronousSynchronizationNeedsAnotherPass = false
                self.synchronizationStateLock.unlock()

                _ = self.handle(
                    request: TimeMachineDiskRequest(operation: .synchronize, wait: true),
                    payload: Data()
                )

                self.synchronizationStateLock.lock()
                if self.asynchronousSynchronizationNeedsAnotherPass {
                    self.synchronizationStateLock.unlock()
                    continue
                }
                self.asynchronousSynchronizationIsScheduled = false
                self.synchronizationStateLock.unlock()
                return
            }
        }
    }

    /// FSKit discards storage metrics on ordinary file operations. Computing
    /// them walks the bounded cache and committed references, so keep that work
    /// off the high-frequency read/write path and perform it only for statfs.
    private func success(
        payload: Data = Data(),
        includeStorageMetrics: Bool = false
    ) -> TimeMachineDiskProtocolResult {
        let usage = includeStorageMetrics ? session.cacheUsage() : nil
        return TimeMachineDiskProtocolResult(
            response: TimeMachineDiskResponse(
                repositoryID: repository.id,
                payloadLength: payload.count,
                generation: head.signedManifest.manifest.generation,
                cleanCacheBytes: usage?.cleanBytes,
                dirtyCacheBytes: usage?.dirtyBytes,
                capacityBytes: includeStorageMetrics ? settings.imageCapacityBytes : nil,
                usedBytes: includeStorageMetrics ? session.usedDataBytes() : nil
            ),
            payload: payload
        )
    }

    private func ensureWriterLease(now: Date = Date()) throws {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        if let terminalLeaseError {
            throw terminalLeaseError
        }
        if lease.expiresAt.timeIntervalSince(now) <= 120 {
            lease = try store.renewLease(lease, duration: 300, now: now)
        }
        // Ordinary writes are still volatile in the bounded dirty cache. Do
        // not issue a remote list/read round trip for every small DiskImages
        // mutation. The independent timer detects lease loss promptly, while
        // the blocking synchronize/commit path verifies the exact lease before
        // upload and again before publishing an acknowledged generation.
    }

    /// A configured cache limit is a local working-set bound, never a maximum
    /// backup size. If an otherwise valid mutation fills that window, move the
    /// existing dirty bands to verified content-addressed remote objects and
    /// retry the exact mutation. The signed generation remains unchanged until
    /// macOS issues its synchronization barrier.
    private func performWithRemoteSpillOnCachePressure(
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            return
        } catch let pressure as TimeMachineSparseFileSessionError {
            guard case .cacheLimitExceeded = pressure else { throw pressure }
            guard let spill = try session.prepareDirtyCacheSpill() else {
                // No valid dirty payload can be spilled. Preserve fail-closed
                // behavior for a corrupt/unmeasurable cache or an impossible
                // request larger than Delta's fixed minimum working window.
                throw pressure
            }
            try store.stageObjects(
                spill.objectsByDigest,
                lease: currentLease()
            )
            guard try session.acceptDirtyCacheSpill(spill) > 0 else {
                throw pressure
            }
            try operation()
        }
    }

    private func currentLease() -> TimeMachineRemoteLease {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        return lease
    }

    private func startLeaseRenewalTimer() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "com.delta.backup.timemachine.lease.\(repository.id.uuidString.lowercased())",
                qos: .utility
            )
        )
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.renewLeaseProactively()
        }
        leaseTimer = timer
        timer.resume()
    }

    private func renewLeaseProactively(now: Date = Date()) {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        guard terminalLeaseError == nil else { return }
        do {
            lease = try store.renewLease(lease, duration: 300, now: now)
        } catch {
            terminalLeaseError = error
            try? publishFailure(error)
        }
    }

    private func publishState(lifecycle: TimeMachineDestinationLifecycle?) throws {
        let usage = session.cacheUsage()
        var state = try database.fetchTimeMachineDestinationState(repositoryID: repository.id)
            ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
        if let lifecycle {
            state.lifecycle = lifecycle
        }
        state.diskImagePath = TimeMachineRuntimePaths.diskImageRelativePath(settings: settings)
        state.committedGeneration = head.signedManifest.manifest.generation
        state.committedManifestDigest = head.signedManifest.manifestDigest
        state.cleanCacheBytes = usage.cleanBytes
        state.dirtyCacheBytes = usage.dirtyBytes
        state.lastError = nil
        state.lastFailureContext = nil
        state.updatedAt = Date()
        try database.saveTimeMachineDestinationState(state)
    }

    private func publishFailure(_ error: Error) throws {
        let usage = session.cacheUsage()
        var state = try database.fetchTimeMachineDestinationState(repositoryID: repository.id)
            ?? TimeMachineDestinationState(repositoryID: repository.id, storeID: settings.storeID)
        // A transport error does not detach the APFS image or unmount FSKit.
        // Preserve the authoritative attachment lifecycle so the app continues
        // to require an explicit disconnect before edit or removal.
        state.cleanCacheBytes = usage.cleanBytes
        state.dirtyCacheBytes = usage.dirtyBytes
        state.lastError = TimeMachineDestinationFailurePresentation.userMessage(for: error)
        state.lastFailureContext = .remoteSynchronization
        state.updatedAt = Date()
        try database.saveTimeMachineDestinationState(state)
    }

    private func recordOperationalWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        do {
            try database.appendEvent(EventLog(level: .warning, message: message))
        } catch {
            logger.error(
                "Could not persist Time Machine warning: \(SensitiveLogRedactor.redact(error.localizedDescription), privacy: .public)"
            )
        }
    }

    private func reportCacheWarningIfNeeded() {
        if let warning = session.takeCacheMaintenanceWarning() {
            recordOperationalWarning(warning)
        }
    }

    private func requiredPath(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else {
            throw TimeMachineSparseFileSessionError.invalidPath(value ?? "")
        }
        return value
    }

    private func requiredOffset(_ value: UInt64?) throws -> UInt64 {
        guard let value else {
            throw TimeMachineSparseFileSessionError.invalidRange
        }
        return value
    }

    static func errorNumber(for error: Error) -> Int32 {
        switch error {
        case TimeMachineSparseFileSessionError.invalidPath,
             TimeMachineSparseFileSessionError.invalidRange,
             TimeMachineSparseFileSessionError.invalidRename:
            return EINVAL
        case TimeMachineSparseFileSessionError.renameDestinationNotEmpty:
            return ENOTEMPTY
        case TimeMachineSparseFileSessionError.cacheLimitExceeded:
            return ENOSPC
        case TimeMachineObjectStoreError.leaseHeld, TimeMachineObjectStoreError.leaseLost:
            return EBUSY
        case TimeMachineRcloneError.commandFailed:
            return ENETDOWN
        case let error as POSIXError:
            return error.code.rawValue
        default:
            return EIO
        }
    }

    static func materializeSparsePlaceholders(
        files: [TimeMachineRemoteFile],
        sourceDirectory: URL,
        repositoryID: UUID
    ) throws {
        let fileManager = FileManager.default
        var componentsByPath: [String: [String]] = [:]
        for file in files {
            let components = try validatedPlaceholderComponents(file.path)
            guard componentsByPath.updateValue(components, forKey: file.path) == nil else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
        }
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sourceDescriptor = Darwin.open(
            sourceDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        defer { _ = Darwin.close(sourceDescriptor) }
        var sourceAttributes = stat()
        guard
            Darwin.fstat(sourceDescriptor, &sourceAttributes) == 0,
            (sourceAttributes.st_mode & S_IFMT) == S_IFDIR,
            sourceAttributes.st_uid == geteuid(),
            (sourceAttributes.st_mode & 0o022) == 0
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
        guard Darwin.fchmod(sourceDescriptor, S_IRWXU) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }

        let expectedPaths = Set(files.map(\.path))
        var expectedDirectories = Set<String>()
        for components in componentsByPath.values {
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                expectedDirectories.insert(components.prefix(count).joined(separator: "/"))
            }
        }
        guard expectedPaths.isDisjoint(with: expectedDirectories) else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        try reconcilePlaceholderDirectory(
            descriptor: sourceDescriptor,
            relativePrefix: "",
            expectedFiles: expectedPaths,
            expectedDirectories: expectedDirectories,
            rootDevice: sourceAttributes.st_dev
        )
        try writeRepositoryMarker(
            repositoryID: repositoryID,
            sourceDescriptor: sourceDescriptor
        )

        for file in files {
            try autoreleasepool {
                guard
                    let components = componentsByPath[file.path],
                    let name = components.last,
                    let logicalSize = off_t(exactly: file.logicalSize)
                else {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                let parentDescriptor = try openPlaceholderDirectoryChain(
                    Array(components.dropLast()),
                    sourceDescriptor: sourceDescriptor,
                    rootDevice: sourceAttributes.st_dev
                )
                defer { _ = Darwin.close(parentDescriptor) }
                let fileDescriptor = Darwin.openat(
                    parentDescriptor,
                    name,
                    O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
                guard fileDescriptor >= 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                var fileError: Error?
                var attributes = stat()
                if Darwin.fstat(fileDescriptor, &attributes) != 0
                    || (attributes.st_mode & S_IFMT) != S_IFREG
                    || attributes.st_uid != geteuid()
                    || attributes.st_nlink != 1
                    || attributes.st_dev != sourceAttributes.st_dev {
                    fileError = POSIXError(.EPERM)
                } else if Darwin.fchmod(fileDescriptor, S_IRUSR | S_IWUSR) != 0
                    || Darwin.ftruncate(fileDescriptor, logicalSize) != 0 {
                    fileError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                if Darwin.close(fileDescriptor) != 0, fileError == nil {
                    fileError = POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                if let fileError { throw fileError }
            }
        }

        var finalSourceAttributes = stat()
        guard
            Darwin.lstat(sourceDirectory.path, &finalSourceAttributes) == 0,
            (finalSourceAttributes.st_mode & S_IFMT) == S_IFDIR,
            finalSourceAttributes.st_dev == sourceAttributes.st_dev,
            finalSourceAttributes.st_ino == sourceAttributes.st_ino,
            finalSourceAttributes.st_uid == sourceAttributes.st_uid
        else {
            throw TimeMachineRuntimePathError.invalidSourceDirectory
        }
    }

    private static func validatedPlaceholderComponents(_ path: String) throws -> [String] {
        guard TimeMachineRemotePathPolicy.isValid(path) else {
            throw TimeMachineSparseFileSessionError.invalidPath(path)
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            !components.isEmpty
        else {
            throw TimeMachineSparseFileSessionError.invalidPath(path)
        }
        return components
    }

    private static func reconcilePlaceholderDirectory(
        descriptor: Int32,
        relativePrefix: String,
        expectedFiles: Set<String>,
        expectedDirectories: Set<String>,
        rootDevice: dev_t
    ) throws {
        for name in try TimeMachineDescriptorTree.entryNames(descriptor: descriptor) {
            if relativePrefix.isEmpty,
               name == TimeMachineRuntimePaths.mountSessionMarkerFileName,
               (try? TimeMachineRuntimePaths.readUUIDMarker(
                    named: name,
                    sourceDescriptor: descriptor,
                    rootDevice: rootDevice,
                    expectedOwnerID: geteuid()
               )) != nil {
                // A live FSKit instance may need to reopen and revalidate its
                // root after the storage service restarts. Preserve only the
                // exact private, valid connection marker; all other stale
                // `.delta-` staging entries remain subject to cleanup.
                continue
            }
            let relative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            var attributes = stat()
            guard Darwin.fstatat(
                descriptor,
                name,
                &attributes,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            let kind = attributes.st_mode & S_IFMT
            let isExpectedFile = expectedFiles.contains(relative)
                && kind == S_IFREG
                && attributes.st_uid == geteuid()
                && attributes.st_nlink == 1
                && attributes.st_dev == rootDevice
            let isExpectedDirectory = expectedDirectories.contains(relative)
                && kind == S_IFDIR
                && attributes.st_uid == geteuid()
                && attributes.st_dev == rootDevice
            if isExpectedFile {
                continue
            }
            if isExpectedDirectory {
                try autoreleasepool {
                    let child = try TimeMachineDescriptorTree.openVerifiedDirectory(
                        parentDescriptor: descriptor,
                        name: name,
                        expectedAttributes: attributes,
                        rootDevice: rootDevice,
                        expectedOwnerID: geteuid()
                    )
                    defer { _ = Darwin.close(child) }
                    try reconcilePlaceholderDirectory(
                        descriptor: child,
                        relativePrefix: relative,
                        expectedFiles: expectedFiles,
                        expectedDirectories: expectedDirectories,
                        rootDevice: rootDevice
                    )
                }
                continue
            }
            try TimeMachineDescriptorTree.remove(
                parentDescriptor: descriptor,
                name: name,
                expectedAttributes: attributes,
                rootDevice: rootDevice,
                expectedOwnerID: geteuid()
            )
        }
    }

    private static func openPlaceholderDirectoryChain(
        _ components: [String],
        sourceDescriptor: Int32,
        rootDevice: dev_t
    ) throws -> Int32 {
        var current = Darwin.fcntl(sourceDescriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        do {
            for component in components {
                if Darwin.mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                let next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                var attributes = stat()
                guard
                    Darwin.fstat(next, &attributes) == 0,
                    (attributes.st_mode & S_IFMT) == S_IFDIR,
                    attributes.st_uid == geteuid(),
                    attributes.st_dev == rootDevice,
                    (attributes.st_mode & 0o022) == 0,
                    Darwin.fchmod(next, S_IRWXU) == 0
                else {
                    _ = Darwin.close(next)
                    throw POSIXError(.EPERM)
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func writeRepositoryMarker(
        repositoryID: UUID,
        sourceDescriptor: Int32
    ) throws {
        try TimeMachineRuntimePaths.writePrivateMarker(
            named: TimeMachineRuntimePaths.repositoryMarkerFileName,
            value: repositoryID,
            sourceDescriptor: sourceDescriptor
        )
    }
}
