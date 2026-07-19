/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class defines a custom volume for use by the passthrough file system.
*/

import Foundation
import DeltaTimeMachineIPC
import ExtensionFoundation
import FSKit
import OSLog

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A PassthroughFSVolume represents a volume in the passthrough file system.
class PassthroughFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.OpenCloseOperations {

    /// The root item of the volume.
    var rootItem: PassthroughFSItem

    /// The item cache stores items previously looked up or created;
    /// items are removed from the dictionary when the volume reclaims or removes the item.
    var itemCache: [UInt64: PassthroughFSItem]

    /// The item cache is accessed concurrently so the volume needs to serialize access to it.
    var itemCacheQueue: DispatchQueue
    let remoteClient: DeltaRemoteFileClient
    let isReadOnly: Bool
    let rootPath: String
    let repositoryID: UUID
    let mountSessionID: UUID
    /// Serializes path-dependent remote I/O with namespace mutations. The
    /// backing service is serialized too, but this lock also keeps an item's
    /// local parent/name snapshot aligned with the remote path used for that
    /// request. It is recursive because create delegates attribute setup to
    /// another volume operation before publishing the new item.
    let operationLock = NSRecursiveLock()

    /// Creates a new PassthroughFSVolume.
    /// - Parameter rootPath: The path to the root directory of the volume.
    init(rootPath: String, isReadOnly: Bool) throws {
        let rootFD = try throwErrno {
            Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        let sourceIdentity: SourceIdentity
        do {
            sourceIdentity = try Self.validatedSourceIdentity(rootDescriptor: rootFD)
        } catch {
            _ = Darwin.close(rootFD)
            throw error
        }
        let remoteClient: DeltaRemoteFileClient
        do {
            remoteClient = try DeltaRemoteFileClient(
                rootPath: rootPath,
                repositoryID: sourceIdentity.repositoryID
            )
            try Self.validateRootPathIdentity(
                rootPath: rootPath,
                rootDescriptor: rootFD
            )
        } catch {
            _ = Darwin.close(rootFD)
            throw error
        }
        do {
            self.rootItem = try PassthroughFSItem(
                name: ".",
                fileDescriptor: rootFD,
                type: .directory,
                openFlags: .readOnly
            )
        } catch {
            _ = Darwin.close(rootFD)
            throw error
        }
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.itemcache.queue")
        self.remoteClient = remoteClient
        self.isReadOnly = isReadOnly
        self.rootPath = rootPath
        self.repositoryID = sourceIdentity.repositoryID
        self.mountSessionID = sourceIdentity.mountSessionID
        super.init(
            volumeID: FSVolume.Identifier(uuid: sourceIdentity.mountSessionID),
            volumeName: createVolumeNameFromPath(rootPath)
        )
        Logger.passthroughfs.info("\(#function): Created a new volume with ID(\(self.volumeID)) and name(\(self.name)) on path(\(rootPath))")
    }

    static func validatedRepositoryID(rootPath: String) throws -> UUID {
        let rootDescriptor = try throwErrno {
            Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        defer { _ = Darwin.close(rootDescriptor) }
        return try validatedSourceIdentity(rootDescriptor: rootDescriptor).repositoryID
    }

    static func validatedRepositoryID(rootDescriptor: Int32) throws -> UUID {
        try validatedSourceIdentity(rootDescriptor: rootDescriptor).repositoryID
    }

    struct SourceIdentity: Equatable {
        let repositoryID: UUID
        let mountSessionID: UUID
    }

    static func validatedSourceIdentity(rootPath: String) throws -> SourceIdentity {
        let rootDescriptor = try throwErrno {
            Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        defer { _ = Darwin.close(rootDescriptor) }
        return try validatedSourceIdentity(rootDescriptor: rootDescriptor)
    }

    static func validatedSourceIdentity(rootDescriptor: Int32) throws -> SourceIdentity {
        var rootAttributes = stat()
        guard
            Darwin.fstat(rootDescriptor, &rootAttributes) == 0,
            (rootAttributes.st_mode & S_IFMT) == S_IFDIR,
            rootAttributes.st_uid == geteuid(),
            (rootAttributes.st_mode & 0o022) == 0
        else {
            throw POSIXError(.EPERM)
        }
        return SourceIdentity(
            repositoryID: try validatedUUIDMarker(
                named: DeltaTimeMachineFileSystemIdentity.repositoryMarkerFileName,
                rootDescriptor: rootDescriptor,
                rootDevice: rootAttributes.st_dev
            ),
            mountSessionID: try validatedUUIDMarker(
                named: DeltaTimeMachineFileSystemIdentity.mountSessionMarkerFileName,
                rootDescriptor: rootDescriptor,
                rootDevice: rootAttributes.st_dev
            )
        )
    }

    private static func validatedUUIDMarker(
        named name: String,
        rootDescriptor: Int32,
        rootDevice: dev_t
    ) throws -> UUID {
        let markerDescriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard markerDescriptor >= 0 else { throw posixErrno }
        defer { _ = Darwin.close(markerDescriptor) }
        var markerAttributes = stat()
        guard
            Darwin.fstat(markerDescriptor, &markerAttributes) == 0,
            (markerAttributes.st_mode & S_IFMT) == S_IFREG,
            markerAttributes.st_uid == geteuid(),
            markerAttributes.st_dev == rootDevice,
            markerAttributes.st_nlink == 1,
            (markerAttributes.st_mode & 0o077) == 0,
            markerAttributes.st_size > 0,
            markerAttributes.st_size <= 128,
            let markerSize = Int(exactly: markerAttributes.st_size)
        else {
            throw POSIXError(.EPERM)
        }
        var data = Data(count: markerSize)
        var offset = 0
        while offset < markerSize {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    markerDescriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    markerSize - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw count == 0 ? POSIXError(.EIO) : posixErrno
            }
            offset += count
        }
        guard
            let marker = String(data: data, encoding: .utf8),
            let value = UUID(
                uuidString: marker.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            throw POSIXError(.EINVAL)
        }
        return value
    }

    private static func validateRootPathIdentity(
        rootPath: String,
        rootDescriptor: Int32
    ) throws {
        var descriptorAttributes = stat()
        var pathAttributes = stat()
        guard
            Darwin.fstat(rootDescriptor, &descriptorAttributes) == 0,
            stat(rootPath, &pathAttributes) == 0,
            pathAttributes.st_dev == descriptorAttributes.st_dev,
            pathAttributes.st_ino == descriptorAttributes.st_ino,
            (pathAttributes.st_mode & S_IFMT) == S_IFDIR
        else {
            throw POSIXError(.ESTALE)
        }
    }

    /// Delta's private outer FSKit transport has a connection-scoped identity
    /// and isn't user-renamable. The encrypted inner APFS volume carries the
    /// stable disk identity presented to Time Machine.
    public var isVolumeRenameInhibited = true

    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(nil, POSIXError(.ENOTSUP))
    }

    func requireWritable() throws {
        guard !isReadOnly else { throw POSIXError(.EROFS) }
    }

    func reopenRootIfNeeded() throws {
        guard rootItem.fileDescriptor < 0 else { return }
        let descriptor = try throwErrno {
            Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        do {
            guard try Self.validatedSourceIdentity(rootDescriptor: descriptor)
                == SourceIdentity(
                    repositoryID: repositoryID,
                    mountSessionID: mountSessionID
                ) else {
                throw POSIXError(.ESTALE)
            }
            try Self.validateRootPathIdentity(
                rootPath: rootPath,
                rootDescriptor: descriptor
            )
            try rootItem.installRootDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Reads the contents of the given file item using `pread`.
    /// - Parameters:
    ///   - item: The file item to read from.
    ///   - offset: The file offset at which to begin reading.
    ///   - length: The number of bytes to read.
    ///   - buffer: The buffer into which to read the data.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func read(from item: FSItem,
                     at offset: off_t,
                     length: Int,
                     into buffer: FSMutableFileDataBuffer,
                     replyHandler: @escaping (Int, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        guard offset >= 0, length >= 0, length <= buffer.length else {
            return replyHandler(0, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard ptItem.itemType == .file, !ptItem.isDeleted else {
            return replyHandler(0, POSIXError(.ESTALE))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(0, error)
            }
        }
        defer {
            if oldFD < 0 { try? ptItem.closeItem() }
        }
        do {
            _ = try ptItem.validatedStatus()
        } catch {
            return replyHandler(0, error)
        }
        if ptItem.itemType == .file, !ptItem.isDeltaControlItem {
            do {
                let data = try remoteClient.read(
                    path: ptItem.relativePath,
                    offset: UInt64(offset),
                    length: length
                )
                guard data.count <= length else {
                    return replyHandler(0, POSIXError(.EIO))
                }
                data.withUnsafeBytes { source in
                    buffer.withUnsafeMutableBytes { destination in
                        guard
                            let sourceBase = source.baseAddress,
                            let destinationBase = destination.baseAddress
                        else {
                            return
                        }
                        destinationBase.copyMemory(
                            from: sourceBase,
                            byteCount: min(data.count, destination.count)
                        )
                    }
                }
                return replyHandler(data.count, nil)
            } catch {
                return replyHandler(0, error)
            }
        }
        var err: Error?
        var actuallyRead = 0
        buffer.withUnsafeMutableBytes { rawBufferPointer in
            actuallyRead = pread(ptItem.fileDescriptor, rawBufferPointer.baseAddress, length, offset)

            // Check if the read operation was successful.
            if actuallyRead == -1 {
                err = posixErrno
            }
        }

        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyRead, nil)

    }

    /// Writes contents to the given file item using `pwrite`.
    /// - Parameters:
    ///   - contents: The data to write to the file item.
    ///   - item: The file item to write to.
    ///   - offset: The file offset at which to begin writing.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }

        do {
            try requireWritable()
        } catch {
            return replyHandler(0, error)
        }
        guard
            offset >= 0,
            let contentCount = off_t(exactly: contents.count),
            offset <= off_t.max - contentCount
        else {
            return replyHandler(0, POSIXError(.EFBIG))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        guard ptItem.itemType == .file, !ptItem.isDeleted else {
            Logger.passthroughfs.error("\(#function): Can't write to a non-live file")
            return replyHandler(0, POSIXError(.ESTALE))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                return replyHandler(0, error)
            }
        }
        defer {
            if oldFD < 0 { try? ptItem.closeItem() }
        }
        do {
            _ = try ptItem.validatedStatus()
        } catch {
            return replyHandler(0, error)
        }

        if ptItem.itemType == .file, !ptItem.isDeltaControlItem {
            var statResult = stat()
            guard fstat(ptItem.fileDescriptor, &statResult) == 0 else {
                return replyHandler(0, posixErrno)
            }
            let previousSize = statResult.st_size
            let end = offset + contentCount
            if end > previousSize, ftruncate(ptItem.fileDescriptor, end) != 0 {
                return replyHandler(0, posixErrno)
            }
            do {
                let written = try remoteClient.write(
                    path: ptItem.relativePath,
                    offset: UInt64(offset),
                    data: contents
                )
                if end > previousSize, written < contents.count {
                    let writtenEnd = offset + off_t(written)
                    let retainedSize = max(previousSize, writtenEnd)
                    guard ftruncate(ptItem.fileDescriptor, retainedSize) == 0 else {
                        return replyHandler(written, posixErrno)
                    }
                }
                return replyHandler(written, nil)
            } catch {
                if end > previousSize {
                    _ = ftruncate(ptItem.fileDescriptor, previousSize)
                }
                return replyHandler(0, error)
            }
        }

        let bytesPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: contents.count)
        contents.copyBytes(to: bytesPtr, count: contents.count)

        var err: Error?
        let actuallyWritten = pwrite(ptItem.fileDescriptor, bytesPtr, contents.count, off_t(offset))
        bytesPtr.deallocate()
        if actuallyWritten == -1 {
            err = posixErrno
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyWritten, nil)
    }

    /// Performs an `open` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to open.
    ///   - modes: The open modes.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func openItem(_ item: FSItem,
                         modes: FSVolume.OpenModes,
                         replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard modes.contains(.read) || modes.contains(.write) else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard !ptItem.isDeleted else {
            return replyHandler(POSIXError(.ESTALE))
        }
        if modes.contains(.write) {
            do {
                try requireWritable()
            } catch {
                return replyHandler(error)
            }
        }
        guard ptItem != self.rootItem else {
            // root item is opened when creating the volume.
            return replyHandler(nil)
        }

        var ptfsMode: PassthroughFSItemOpenMode = .close
        if modes.contains(.read) {
            ptfsMode = .readOnly
        }
        if modes.contains(.write) {
            ptfsMode = .readWrite
        }

        do {
            try ptItem.upgradeOpenMode(mode: ptfsMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Performs a `close` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to close.
    ///   - modes: The open modes (ignored for PassthroughFS).
    ///   - replyHandler: The reply handler to invoke with the result.
    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        if modes.contains(.write) {
            do {
                try requireWritable()
            } catch {
                return replyHandler(error)
            }
        }
        guard ptItem != self.rootItem else {
            // Root item is closed in deactivate volume.
            return replyHandler(nil)
        }

        let retainedMode: PassthroughFSItemOpenMode
        if modes.contains(.write) {
            retainedMode = .readWrite
        } else if modes.contains(.read) {
            retainedMode = .readOnly
        } else {
            retainedMode = .close
        }
        do {
            try ptItem.retainOpenMode(mode: retainedMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Get maximum link count using `fpathconf`.
    public var maximumLinkCount: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_LINK_MAX))
    }

    /// Get maximum name length using `fpathconf`.
    public var maximumNameLength: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_NAME_MAX))
    }

    /// Get whether the volume restricts ownership changes based on authorization using `fpathconf`.
    public var restrictsOwnershipChanges: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_CHOWN_RESTRICTED) == 1
    }

    /// Get whether the volume truncates files longer than its maximum supported length using `fpathconf`.
    public var truncatesLongNames: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_NO_TRUNC) == 0
    }

    /// Get the maximum file size in bits using `fpathconf`.
    public var maximumFileSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_FILESIZEBITS))
    }

    /// Get the maximum extended attribute size in bits using `fpathconf`.
    public var maximumXattrSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_XATTR_SIZE_BITS))
    }
}
