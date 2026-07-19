/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The implementation of the passthrough file system's conformance to the operations required of an FSKit volume.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog


/// A structure that holds common attributes for all items.
private struct CommonAttributes {
    var length: UInt32
    var backupTime: timespec
    var parentID: UInt64
    var addedTime: timespec

    init() {
        self.length = 0
        self.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        self.parentID = 0
        self.addedTime = timespec(tv_sec: 0, tv_nsec: 0)
    }
}

/// Implementing FSVolume.Operations.
extension PassthroughFSVolume: FSVolume.Operations {

    /// Returns volume statistics using `fstatfs`.
    public var volumeStatistics: FSStatFSResult {
        operationLock.lock()
        defer { operationLock.unlock() }
        var statfsResult = statfs()
        let res = FSStatFSResult(fileSystemTypeName: String("delta-tm"))
        if fstatfs(self.rootItem.fileDescriptor, &statfsResult) == -1 {
            return res
        }
        // Convert the statfs result to FSStatFSResult
        let blockSize = max(Int(statfsResult.f_bsize), 4_096)
        // A disconnected or malformed backend must never make Time Machine
        // believe the remote disk has abundant free space. FSVolume exposes no
        // throwing statfs hook, so report the last authenticated capacity as
        // fully used until the service can answer authoritatively again.
        let storage = (try? remoteClient.storageStatus())
            ?? (
                capacityBytes: remoteClient.capacityBytes,
                usedBytes: remoteClient.capacityBytes
            )
        let totalBlocks = UInt64(max(storage.capacityBytes, 0)) / UInt64(blockSize)
        let usedBlocks = min(
            totalBlocks,
            (UInt64(max(storage.usedBytes, 0)) + UInt64(blockSize) - 1) / UInt64(blockSize)
        )
        res.blockSize           = blockSize
        res.ioSize              = 1_048_576
        res.totalBlocks         = totalBlocks
        res.availableBlocks     = totalBlocks - usedBlocks
        res.freeBlocks          = totalBlocks - usedBlocks
        res.usedBlocks          = usedBlocks
        res.totalFiles          = UInt64(statfsResult.f_files)
        res.freeFiles           = UInt64(statfsResult.f_ffree)
        // The extension declares no FSKit personalities/subtypes; don't leak
        // the Application Support volume's APFS subtype into the virtual disk.
        res.fileSystemSubType   = 0
        return res
    }

    /// Activates the volume, but PassthroughFS volume activation doesn't need to do anything, so this method just replies with the root item.
    ///
    /// - Parameters
    ///   - options: The activation options.
    ///   - reply: The reply handler to invoke when the activation is complete.
    public func activate(options: FSTaskOptions,
                         replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            try reopenRootIfNeeded()
            return reply(self.rootItem, nil)
        } catch {
            return reply(nil, error)
        }
    }

    /// Deactivates the volume, by closing the root item.
    /// - Parameters:
    ///   - options: The deactivation options.
    ///   - replyHandler: The reply handler to invoke when the deactivation is complete.
    public func deactivate(options: FSDeactivateOptions = [],
                           replyHandler: @escaping ((any Error)?) -> Void) {
        operationLock.lock()
        defer { operationLock.unlock() }
        let cachedItems = itemCacheQueue.sync { () -> [PassthroughFSItem] in
            let items = Array(itemCache.values)
            itemCache.removeAll()
            return items
        }
        var firstCloseError: Error?
        for item in cachedItems {
            do {
                try item.closeItem()
            } catch {
                firstCloseError = firstCloseError ?? error
            }
        }
        do {
            try rootItem.closeItem()
        } catch {
            firstCloseError = firstCloseError ?? error
        }
        if let firstCloseError, !options.contains(.force) {
            return replyHandler(firstCloseError)
        }
        if let firstCloseError {
            Logger.passthroughfs.error("\(#function): Forced deactivation after descriptor cleanup failed: \(firstCloseError)")
        }
        return replyHandler(nil)
    }

    /// Mount in PassthroughFSVolume doesn't need to do anything; implementation just replies with nil error.
    public func mount(options: FSTaskOptions,
                      replyHandler: @escaping (Error?) -> Void) {
        return replyHandler(nil)
    }

    /// Unmount performs a final durability barrier. The root remains open
    /// because FSKit can mount an already-active volume again; deactivate owns
    /// descriptor teardown.
    public func unmount(replyHandler: @escaping () -> Void) {
        operationLock.lock()
        defer { operationLock.unlock() }
        if fsync(self.rootItem.fileDescriptor) != 0 {
            Logger.passthroughfs.error("\(#function): Placeholder metadata flush failed: \(posixErrno)")
        }
        do {
            try remoteClient.synchronize(wait: true)
        } catch {
            // FSKit's unmount callback has no error parameter. Keep the failure
            // visible in the service's durable destination state and unified
            // log. FSKit's preceding synchronize callback is the error-bearing
            // durability gate; deactivate is teardown-only by contract.
            Logger.passthroughfs.error("\(#function): Remote generation flush failed: \(error)")
        }
        return replyHandler()
    }

    /// Flushes placeholder metadata, then starts or waits for the authenticated
    /// remote generation according to FSKit's synchronization flag.
    /// - Parameters
    ///   - flags: The sync flags.
    ///   - reply: The reply handler to invoke when the sync is complete.
    public func synchronize(flags: FSSyncFlags,
                            replyHandler reply: @escaping ((any Error)?) -> Void) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard fsync(self.rootItem.fileDescriptor) == 0 else {
            let err = posixErrno
            Logger.passthroughfs.error("\(#function): Failed to synchronize with error(\(err))")
            return reply(err)
        }
        do {
            try remoteClient.synchronize(wait: flags != .noWait)
            return reply(nil)
        } catch {
            return reply(error)
        }
    }

    private func getCommonAttributes(ptItem: PassthroughFSItem,
                                     desiredAttributes: FSItem.GetAttributesRequest) throws -> CommonAttributes {

        var attrgroupFlags: Int32 = 0
        if desiredAttributes.isAttributeWanted(.parentID) {
            attrgroupFlags |= ATTR_CMN_PARENTID
        }
        if desiredAttributes.isAttributeWanted(.addedTime) {
            attrgroupFlags |= ATTR_CMN_ADDEDTIME
        }
        if desiredAttributes.isAttributeWanted(.backupTime) {
            attrgroupFlags |= ATTR_CMN_BKUPTIME
        }
        let commonAttrsWanted = attrgroup_t(attrgroupFlags)
        var attrList = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: commonAttrsWanted,
                                volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var commonAttrsBuf = CommonAttributes()

        if attrgroupFlags != 0 {
            if fgetattrlist(ptItem.fileDescriptor, &attrList, &commonAttrsBuf, MemoryLayout<CommonAttributes>.size, UInt32(FSOPT_NOFOLLOW)) == -1 {
                throw posixErrno
            }
        }
        return commonAttrsBuf
    }

    /// Fetches attributes for the given item.
    /// The method uses `stat`, and `fgetattrlist` to get the attributes.
    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                              of item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't open given item (\(ptItem.name)) error (\(error))")
                return replyHandler(nil, error)
            }
        }
        defer {
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
        }

        let statResult: stat
        do {
            statResult = try ptItem.validatedStatus()
        } catch {
            return replyHandler(nil, error)
        }

        var commonAttrsBuf: CommonAttributes
        do {
            commonAttrsBuf = try self.getCommonAttributes(ptItem: ptItem, desiredAttributes: desiredAttributes)
        } catch {
            Logger.passthroughfs.error("\(#function): Can't get commont attributes for item (\(ptItem.name))")
            replyHandler(nil, error)
            return
        }

        let attrs = FSItem.Attributes()

        if desiredAttributes.isAttributeWanted(.uid) {
            attrs.uid = statResult.st_uid
        }

        if desiredAttributes.isAttributeWanted(.gid) {
            attrs.gid = statResult.st_gid
        }

        if desiredAttributes.isAttributeWanted(.mode) {
            attrs.mode = UInt32(Int32(statResult.st_mode) & modeAllBits)
        }

        if desiredAttributes.isAttributeWanted(.linkCount) {
            attrs.linkCount = UInt32(statResult.st_nlink)
        }

        if desiredAttributes.isAttributeWanted(.flags) {
            attrs.flags = statResult.st_flags
        }

        if desiredAttributes.isAttributeWanted(.size) {
            attrs.size = UInt64(statResult.st_size)
        }

        if desiredAttributes.isAttributeWanted(.allocSize) {
            // st_blocks is always expressed in 512-byte units on Darwin.
            attrs.allocSize = UInt64(statResult.st_blocks) * 512
        }

        if desiredAttributes.isAttributeWanted(.fileID) {
            attrs.fileID = FSItem.Identifier(rawValue: statResult.st_ino) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.parentID) {
            attrs.parentID = FSItem.Identifier(rawValue: commonAttrsBuf.parentID) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.type) {
            attrs.type = ptItem.itemType
        }

        var timeSpec: timespec

        if desiredAttributes.isAttributeWanted(.accessTime) {
            timeSpec = statResult.st_atimespec
            attrs.accessTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.changeTime) {
            timeSpec = statResult.st_ctimespec
            attrs.changeTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.modifyTime) {
            timeSpec = statResult.st_mtimespec
            attrs.modifyTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.addedTime) {
            timeSpec = commonAttrsBuf.addedTime
            attrs.addedTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.birthTime) {
            timeSpec = statResult.st_birthtimespec
            attrs.birthTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.backupTime) {
            timeSpec = commonAttrsBuf.backupTime
            attrs.backupTime = timeSpec
        }

        replyHandler(attrs, nil)
    }

    /// Set item attributes.
    /// The method uses `ftruncate`, `fchmod`, `futimes`, `fchown`, and `fchflags`  to set the attributes.
    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              creatingNewFile: Bool,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            try requireWritable()
        } catch {
            return replyHandler(nil, error)
        }
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !ptItem.isDeleted else {
            return replyHandler(nil, POSIXError(.ESTALE))
        }

        // Check that this request doesn't attempt to change read-only fields, raising an error if it does.
        if (creatingNewFile == false) &&
            (newAttributes.isValid(.type) || newAttributes.isValid(.linkCount) ||
             newAttributes.isValid(.allocSize) || newAttributes.isValid(.fileID) ||
             newAttributes.isValid(.parentID) || newAttributes.isValid(.changeTime)) {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        if newAttributes.isValid(.mode) && ((Int32(newAttributes.mode) & ~modeAllBits) != 0) {
            // Bits outside of the supported mode bits are specified.
            Logger.passthroughfs.error("\(#function): Invalid mode bits for item (\(ptItem.name)), returning EINVAL")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        if newAttributes.isValid(.size) {
            guard
                ptItem.itemType == .file,
                newAttributes.size <= UInt64(Int64.max)
            else {
                return replyHandler(nil, POSIXError(.EFBIG))
            }
        }
        if newAttributes.isValid(.flags) {
            let supportedBSDFlags = UInt32(UF_HIDDEN)
            guard newAttributes.flags & ~supportedBSDFlags == 0 else {
                return replyHandler(nil, POSIXError(.EINVAL))
            }
        }
        if newAttributes.isValid(.accessTime),
           (newAttributes.accessTime.tv_nsec < 0
                || newAttributes.accessTime.tv_nsec >= 1_000_000_000)
        {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        if newAttributes.isValid(.modifyTime),
           (newAttributes.modifyTime.tv_nsec < 0
                || newAttributes.modifyTime.tv_nsec >= 1_000_000_000)
        {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        var getAttrs: FSItem.Attributes?
        var getAttrsError: Error?
        let getAttrRequest: FSItem.GetAttributesRequest = FSItem.GetAttributesRequest()
        getAttrRequest.wantedAttributes = [.gid, .uid, .mode, .size, .allocSize,
                                           .type, .fileID, .parentID, .flags,
                                           .linkCount, .accessTime, .birthTime,
                                           .modifyTime, .changeTime]

        if newAttributes.isValid(.accessTime) ||
            newAttributes.isValid(.modifyTime) ||
            newAttributes.isValid(.uid)        ||
            newAttributes.isValid(.gid) {
            self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
                getAttrsError = error
                getAttrs = attrs
            }
            guard getAttrsError == nil, getAttrs != nil else {
                return replyHandler(nil, getAttrsError ?? POSIXError(.EIO))
            }
        }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set item attributes")
                return replyHandler(nil, error)
            }
        }
        defer {
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
        }
        do {
            _ = try ptItem.validatedStatus()
        } catch {
            return replyHandler(nil, error)
        }

        if newAttributes.isValid(.size) {
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to ftruncate")
                return replyHandler(nil, error)
            }
            var previousStat = stat()
            guard fstat(ptItem.fileDescriptor, &previousStat) == 0 else {
                return replyHandler(nil, posixErrno)
            }
            if ftruncate(ptItem.fileDescriptor, Int64(newAttributes.size)) < 0 {
                return replyHandler(nil, posixErrno)
            }
            if !ptItem.isDeltaControlItem, !creatingNewFile {
                do {
                    try remoteClient.truncate(path: ptItem.relativePath, size: newAttributes.size)
                } catch {
                    _ = ftruncate(ptItem.fileDescriptor, previousStat.st_size)
                    return replyHandler(nil, error)
                }
            }
        }

        if newAttributes.isValid(.mode) {
            let updatedMode = ((Int32(newAttributes.mode) & modeAllBits))
            if fchmod(ptItem.fileDescriptor, mode_t(updatedMode)) < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        if newAttributes.isValid(.accessTime) || newAttributes.isValid(.modifyTime) {
            guard let existingAttributes = getAttrs else {
                return replyHandler(nil, POSIXError(.EIO))
            }
            var accessTime = timespec(tv_sec: 0, tv_nsec: 0)
            var modifyTime = timespec(tv_sec: 0, tv_nsec: 0)

            if newAttributes.isValid(.accessTime) {
                accessTime = newAttributes.accessTime
            } else {
                accessTime = existingAttributes.accessTime
            }

            if newAttributes.isValid(.modifyTime) {
                modifyTime = newAttributes.modifyTime
            } else {
                modifyTime = existingAttributes.modifyTime
            }

            var times = [
                timeval(tv_sec: accessTime.tv_sec, tv_usec: (__darwin_suseconds_t)(accessTime.tv_nsec / 1000)),
                timeval(tv_sec: modifyTime.tv_sec, tv_usec: (__darwin_suseconds_t)(modifyTime.tv_nsec / 1000))
            ]
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set futimes")
                return replyHandler(nil, error)
            }
            let result = times.withUnsafeMutableBufferPointer { pointer in
                futimes(ptItem.fileDescriptor, pointer.baseAddress)
            }
            if result < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        // Change the owner attribute last, since doing so earlier may prevent changing other things.
        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            guard let existingAttributes = getAttrs else {
                return replyHandler(nil, POSIXError(.EIO))
            }
            var newUid: uid_t = 0
            var newGid: gid_t = 0

            if newAttributes.isValid(.uid) {
                newUid = newAttributes.uid
            } else {
                newUid = existingAttributes.uid
            }

            newGid = newAttributes.isValid(.gid) ? newAttributes.gid : existingAttributes.gid

            if fchown(ptItem.fileDescriptor, newUid, newGid) < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        // Hidden is applied after every other requested mutation.
        if newAttributes.isValid(.flags) {
            if fchflags(ptItem.fileDescriptor, newAttributes.flags) < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
            getAttrsError = error
            getAttrs = attrs
        }
        replyHandler(getAttrs, getAttrsError)
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        return self.setAttributes(newAttributes, on: item, creatingNewFile: false, replyHandler: replyHandler)
    }

    /// Performs a lookup on the given directory for the given name.
    /// Lookup is done by `fstatat`. If the item isn't in in the volume's item cache,  add it.
    /// - Parameters:
    ///   - name: The name of the item to lookup.
    ///   - directory: The directory to search.
    ///   - replyHandler: The handler to call when the lookup is complete.
    public func lookupItem(named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast directory")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        let nameString: String
        do {
            nameString = try validatedFSComponent(name)
        } catch {
            return replyHandler(nil, nil, error)
        }
        if nameString.hasPrefix(".delta-") {
            return replyHandler(nil, nil, POSIXError(.ENOENT))
        }

        // Check if item exists in item cache.
        let type: FSItem.ItemType
        var statResult = stat()
        let oldFD = dirItem.fileDescriptor
        do {
            if oldFD < 0 {
                try dirItem.upgradeOpenMode(mode: .readOnly)
            }
            defer {
                if oldFD < 0 { try? dirItem.closeItem() }
            }
            _ = try throwErrno { fstatat(dirItem.fileDescriptor, nameString, &statResult, AT_SYMLINK_NOFOLLOW) }
            if (statResult.st_mode & S_IFMT) == S_IFREG, statResult.st_nlink != 1 {
                return replyHandler(nil, nil, POSIXError(.ENOTSUP))
            }
            let inode = statResult.st_ino
            var val: PassthroughFSItem?
            self.itemCacheQueue.sync {
                if let cached = self.itemCache[inode],
                   !cached.isDeleted,
                   cached.name == nameString,
                   cached.parent === dirItem {
                    val = cached
                }
            }
            if val != nil {
                return replyHandler(val, nil, nil)
            }
            guard let discoveredType = fsItemType(forPOSIXMode: statResult.st_mode) else {
                return replyHandler(nil, nil, POSIXError(.ENOTSUP))
            }
            type = discoveredType
        } catch {
            return replyHandler(nil, nil, error)
        }

        // Item isn't in the item cache, create a new item, update the cache,  and return it.
        var newItem: PassthroughFSItem
        do {
            newItem = try PassthroughFSItem(name: nameString, parent: dirItem, type: type)
        } catch {
            Logger.passthroughfs.error("\(#function): Can't create new item (\(name.debugDescription)) error (\(error)")
            return replyHandler(nil, nil, error)
        }

        if newItem.inode != 0 {
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
        }
        return replyHandler(newItem, name, nil)
    }

    /// Performs reclamation of an item, by removing the item from the item cache, and closing it.
    /// - Parameters:
    ///   - item: The item to be reclaimed.
    ///   - replyHandler: The reply handler to invoke.
    public func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        self.itemCacheQueue.sync {
            if self.itemCache[ptItem.inode] === ptItem {
                self.itemCache.removeValue(forKey: ptItem.inode)
            }
        }
        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Reads a symbolic link, by calling `freadlink`.
    /// - Parameters
    ///   - item: The item to be read.
    ///   - replyHandler: The reply handler to invoke.
    public func readSymbolicLink(_ item: FSItem,
                                 replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard ptItem.itemType == .symlink else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(nil, error)
            }
        }
        defer {
            if oldFD < 0 { try? ptItem.closeItem() }
        }
        let capacity = maxSymlinkSize + 1
        let buf = UnsafeMutablePointer<UTF8>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        let bytesRead = freadlink(ptItem.fileDescriptor, buf, capacity)
        if bytesRead < 0 {
            return replyHandler(nil, posixErrno)
        }
        guard bytesRead <= maxSymlinkSize else {
            return replyHandler(nil, POSIXError(.ENAMETOOLONG))
        }
        let data = Data(bytes: buf, count: bytesRead)
        return replyHandler(FSFileName(data: data), nil)
    }

    /// Performs the creation of a new item in the specified directory, using `mkdirat` and `openat`.
    /// - Parameters:
    ///   - name: The name of the item to create.
    ///   - type: The type of the item to create.
    ///   - directory: The directory in which to create the item.
    ///   - newAttributes: The attributes of the new item.
    ///   - replyHandler: The reply handler to invoke.
    public func createItem(named name: FSFileName,
                           type: FSItem.ItemType,
                           inDirectory directory: FSItem,
                           attributes newAttributes: FSItem.SetAttributesRequest,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            try requireWritable()
        } catch {
            Logger.passthroughfs.error("\(#function): Volume is read-only: \(error)")
            return replyHandler(nil, nil, error)
        }
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast dirItem")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        let nameString: String
        do {
            nameString = try validatedFSComponent(name)
        } catch {
            return replyHandler(nil, nil, error)
        }
        if nameString.hasPrefix(".delta-") {
            return replyHandler(nil, nil, POSIXError(.EACCES))
        }

        if (type == .file || type == .symlink) && !newAttributes.isValid(.mode) {
            Logger.passthroughfs.error("\(#function): attributes doesn't contain a valid mode.")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let oldDirItemFD = dirItem.fileDescriptor
        if oldDirItemFD < 0 {
            do {
                try dirItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(nil, nil, error)
            }
        }
        defer {
            if oldDirItemFD < 0 {
                try? dirItem.closeItem()
            }
        }

        var newItem: PassthroughFSItem
        var error: Int32 = -1
        var fileDescriptor: Int32 = -1
        nameString.withCString({ namePtr in
            switch type {
            case FSItem.ItemType.directory:
                error = mkdirat(dirItem.fileDescriptor, namePtr, S_IRWXU)
            case FSItem.ItemType.file:
                let createFlags = O_RDWR | O_CREAT | O_NOFOLLOW | O_SYMLINK | O_EXCL
                fileDescriptor = openat(dirItem.fileDescriptor, namePtr, createFlags, S_IRWXU)
                if fileDescriptor >= 0 {
                    // Closing the fd, as we're about to open the file again when creating the item.
                    // (that way we have the same flow for files and dirs).
                    error = Darwin.close(fileDescriptor)
                } else {
                    error = -1
                }
            default:
                error = -1
                errno = EINVAL
            }
        })
        guard error != -1 else {
            let creationError = posixErrno
            Logger.passthroughfs.error("\(#function): Local namespace creation failed: \(creationError)")
            return replyHandler(nil, nil, creationError)
        }

        do {
            try newItem = PassthroughFSItem(name: nameString, parent: dirItem, type: type)
        } catch {
            nameString.withCString { namePointer in
                _ = unlinkat(
                    dirItem.fileDescriptor,
                    namePointer,
                    type == .directory ? AT_REMOVEDIR : 0
                )
            }
            return replyHandler(nil, nil, error)
        }

        self.setAttributes(newAttributes, on: newItem, creatingNewFile: true, replyHandler: { (attrs, error) -> Void in
            guard error == nil else {
                let attributeError = String(describing: error)
                Logger.passthroughfs.error(
                    "\(#function): Initial attribute update failed: \(attributeError, privacy: .public)"
                )
                try? dirItem.upgradeOpenMode(mode: .readWrite)
                nameString.withCString { namePointer in
                    _ = unlinkat(dirItem.fileDescriptor, namePointer, type == .directory ? AT_REMOVEDIR : 0)
                }
                return replyHandler(nil, nil, error)
            }
            if type == .file {
                do {
                    let initialSize = newAttributes.isValid(.size)
                        ? newAttributes.size
                        : 0
                    try self.remoteClient.create(
                        path: newItem.relativePath,
                        size: initialSize
                    )
                } catch {
                    Logger.passthroughfs.error("\(#function): Remote file creation failed: \(error)")
                    do {
                        try self.remoteClient.remove(path: newItem.relativePath)
                    } catch {
                        Logger.passthroughfs.fault("\(#function): Could not roll back an ambiguous remote file creation")
                    }
                    try? dirItem.upgradeOpenMode(mode: .readWrite)
                    nameString.withCString { namePointer in
                        _ = unlinkat(dirItem.fileDescriptor, namePointer, 0)
                    }
                    return replyHandler(nil, nil, error)
                }
            }
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, error)
        })
    }

    /// Creates a new symbolic link using `symlinkat`.
    /// - Parameters:
    ///   - name: The name of the file to create.
    ///   - directory: The directory in which to create the symbolic link.
    ///   - newAttributes: The attributes to set on the newly created item.
    ///   - contents: The contents of the symbolic link.
    ///   - replyHandler: The handler to invoke when the operation completes.
    public func createSymbolicLink(named name: FSFileName,
                                   inDirectory directory: FSItem,
                                   attributes newAttributes: FSItem.SetAttributesRequest,
                                   linkContents contents: FSFileName,
                                   replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        replyHandler(nil, nil, POSIXError(.ENOTSUP))
    }

    /// Creation of hard links aren't support for PassthroughFS.
    public func createLink(to item: FSItem,
                           named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        return replyHandler(nil, POSIXError(.ENOTSUP))
    }

    /// Performs the actual removal of the given item from the given directory.
    /// - Parameters:
    ///   - item: The item to remove.
    ///   - name: The name of the item to remove.
    ///   - directory: The directory in which the item should be removed.
    ///   - replyHandler: The handler to call when the removal is complete.
    public func removeItem(_ item: FSItem,
                           named name: FSFileName,
                           fromDirectory directory: FSItem,
                           replyHandler: @escaping (Error?) -> Void) {
        do {
            try requireWritable()
        } catch {
            return replyHandler(error)
        }
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast dirItem")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let nameString: String
        do {
            nameString = try validatedFSComponent(name)
        } catch {
            return replyHandler(error)
        }
        guard
            !nameString.hasPrefix(".delta-"),
            !ptItem.isDeleted,
            ptItem.name == nameString,
            ptItem.parent === dirItem
        else {
            return replyHandler(POSIXError(.ENOENT))
        }

        let unlinkFlags = (ptItem.itemType == FSItem.ItemType.directory) ? AT_REMOVEDIR : 0
        var error: Int32 = -1

        let oldDirItemFD = dirItem.fileDescriptor
        if oldDirItemFD < 0 {
            do {
                try dirItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(error)
            }
        }
        defer {
            if oldDirItemFD < 0 {
                try? dirItem.closeItem()
            }
        }
        var currentItemAttributes = stat()
        guard fstatat(
            dirItem.fileDescriptor,
            nameString,
            &currentItemAttributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return replyHandler(posixErrno)
        }
        guard
            currentItemAttributes.st_ino == ptItem.inode,
            matchesPOSIXFileType(currentItemAttributes, itemType: ptItem.itemType),
            ptItem.itemType != .file || currentItemAttributes.st_nlink == 1
        else {
            return replyHandler(POSIXError(.ESTALE))
        }
        if ptItem.itemType == .file, !ptItem.isDeltaControlItem {
            let stagedName = ".delta-pending-remove-\(UUID().uuidString)"
            nameString.withCString { namePtr in
                stagedName.withCString { stagedNamePtr in
                    error = renameatx_np(
                        dirItem.fileDescriptor,
                        namePtr,
                        dirItem.fileDescriptor,
                        stagedNamePtr,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard error != -1 else {
                return replyHandler(posixErrno)
            }
            do {
                try remoteClient.remove(path: ptItem.relativePath)
            } catch let remoteError {
                var rollbackResult: Int32 = -1
                stagedName.withCString { stagedNamePtr in
                    nameString.withCString { namePtr in
                        rollbackResult = renameatx_np(
                            dirItem.fileDescriptor,
                            stagedNamePtr,
                            dirItem.fileDescriptor,
                            namePtr,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard rollbackResult == 0 else {
                    Logger.passthroughfs.fault("\(#function): Failed to restore a locally staged item after remote removal failed")
                    return replyHandler(POSIXError(.EIO))
                }
                return replyHandler(remoteError)
            }
            var cleanupResult: Int32 = -1
            stagedName.withCString { stagedNamePtr in
                cleanupResult = unlinkat(dirItem.fileDescriptor, stagedNamePtr, 0)
            }
            if cleanupResult != 0 {
                Logger.passthroughfs.error("\(#function): A hidden removed placeholder could not be reclaimed: \(posixErrno)")
            }
        } else {
            nameString.withCString { namePtr in
                error = unlinkat(dirItem.fileDescriptor, namePtr, unlinkFlags)
            }
            if error == -1 {
                return replyHandler(posixErrno)
            }
        }

        // FSKit owns the item object until reclaimItem. Mark the namespace
        // entry deleted, but retain the object for outstanding references.
        self.itemCacheQueue.sync {
            ptItem.isDeleted = true
        }
        replyHandler(nil)

    }

    /// Performs a rename operation on a file system item.
    /// - Parameters:
    ///   - item: The file system item to rename.
    ///   - sourceDirectory: The directory containing the source file system item.
    ///   - sourceName: The name of the item to rename.
    ///   - destinationName: The name of the destination file system item.
    ///   - destinationDirectory: The directory to move the item into.
    ///   - overItem: The item that should be overwritten if it already exists.
    ///   - replyHandler: The reply handler to call when the operation is complete.
    public func renameItem(_ item: FSItem,
                           inDirectory sourceDirectory: FSItem,
                           named sourceName: FSFileName,
                           to destinationName: FSFileName,
                           inDirectory destinationDirectory: FSItem,
                           overItem: FSItem?,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        do {
            try requireWritable()
        } catch {
            return replyHandler(nil, error)
        }
        guard let fromItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast sourceName")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let fromDir = sourceDirectory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast sourceDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let toDir = destinationDirectory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast destinationDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        let fromItemInode = fromItem.inode

        let sourceString: String
        let destinationString: String
        do {
            sourceString = try validatedFSComponent(sourceName)
            destinationString = try validatedFSComponent(destinationName)
        } catch {
            return replyHandler(nil, error)
        }
        guard
            !sourceString.hasPrefix(".delta-"),
            !destinationString.hasPrefix(".delta-")
        else {
            return replyHandler(nil, POSIXError(.EACCES))
        }
        if fromDir === toDir, sourceString == destinationString {
            return replyHandler(destinationName, nil)
        }
        guard
            !fromItem.isDeleted,
            fromItem.name == sourceString,
            fromItem.parent === fromDir
        else {
            return replyHandler(nil, POSIXError(.ENOENT))
        }
        let replacedItem: PassthroughFSItem?
        if let overItem {
            guard let candidate = overItem as? PassthroughFSItem else {
                Logger.passthroughfs.error("\(#function): Can't cast toItem")
                return replyHandler(nil, POSIXError(.EINVAL))
            }
            guard
                candidate !== fromItem,
                !candidate.isDeleted,
                candidate.name == destinationString,
                candidate.parent === toDir
            else {
                return replyHandler(nil, POSIXError(.ESTALE))
            }
            replacedItem = candidate
        } else {
            replacedItem = nil
        }
        let replacedItemType = replacedItem?.itemType
        if let replacedItemType, replacedItemType != fromItem.itemType {
            return replyHandler(
                nil,
                POSIXError(fromItem.itemType == .directory ? .ENOTDIR : .EISDIR)
            )
        }

        let oldFromDirectoryFD = fromDir.fileDescriptor
        if oldFromDirectoryFD < 0 {
            do {
                try fromDir.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(nil, error)
            }
        }
        var oldToDirectoryFD = toDir.fileDescriptor
        if toDir !== fromDir, oldToDirectoryFD < 0 {
            do {
                try toDir.upgradeOpenMode(mode: .readOnly)
            } catch {
                if oldFromDirectoryFD < 0 { try? fromDir.closeItem() }
                return replyHandler(nil, error)
            }
            oldToDirectoryFD = -1
        }
        defer {
            if toDir !== fromDir, oldToDirectoryFD < 0 { try? toDir.closeItem() }
            if oldFromDirectoryFD < 0 { try? fromDir.closeItem() }
        }

        var currentSourceAttributes = stat()
        guard fstatat(
            fromDir.fileDescriptor,
            sourceString,
            &currentSourceAttributes,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return replyHandler(nil, posixErrno)
        }
        guard
            currentSourceAttributes.st_ino == fromItem.inode,
            matchesPOSIXFileType(currentSourceAttributes, itemType: fromItem.itemType),
            fromItem.itemType != .file || currentSourceAttributes.st_nlink == 1
        else {
            return replyHandler(nil, POSIXError(.ESTALE))
        }
        if let replacedItem {
            var currentDestinationAttributes = stat()
            guard fstatat(
                toDir.fileDescriptor,
                destinationString,
                &currentDestinationAttributes,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return replyHandler(nil, posixErrno)
            }
            guard
                currentDestinationAttributes.st_ino == replacedItem.inode,
                matchesPOSIXFileType(currentDestinationAttributes, itemType: replacedItem.itemType),
                replacedItem.itemType != .file || currentDestinationAttributes.st_nlink == 1
            else {
                return replyHandler(nil, POSIXError(.ESTALE))
            }
        }

        let oldRemotePath = fromItem.relativePath
        let stagedDestinationName = replacedItem == nil
            ? nil
            : ".delta-pending-replaced-\(UUID().uuidString)"
        if let stagedDestinationName {
            var stageResult: Int32 = -1
            destinationString.withCString { destinationPointer in
                stagedDestinationName.withCString { stagedPointer in
                    stageResult = renameatx_np(
                        toDir.fileDescriptor,
                        destinationPointer,
                        toDir.fileDescriptor,
                        stagedPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard stageResult != -1 else {
                return replyHandler(nil, posixErrno)
            }
            if replacedItemType == .directory {
                do {
                    guard try directoryIsEmpty(
                        named: stagedDestinationName,
                        in: toDir.fileDescriptor,
                        expectedInode: replacedItem?.inode
                    ) else {
                        throw POSIXError(.ENOTEMPTY)
                    }
                } catch {
                    var restoreResult: Int32 = -1
                    stagedDestinationName.withCString { stagedPointer in
                        destinationString.withCString { destinationPointer in
                            restoreResult = renameatx_np(
                                toDir.fileDescriptor,
                                stagedPointer,
                                toDir.fileDescriptor,
                                destinationPointer,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                    guard restoreResult == 0 else {
                        Logger.passthroughfs.fault("\(#function): Failed to restore a rejected replacement directory")
                        return replyHandler(nil, POSIXError(.EIO))
                    }
                    return replyHandler(nil, error)
                }
            }
        }

        var renameResult: Int32 = -1
        sourceString.withCString { sourcePointer in
            destinationString.withCString { destinationPointer in
                renameResult = renameatx_np(
                    fromDir.fileDescriptor,
                    sourcePointer,
                    toDir.fileDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult == -1 {
            let renameError = posixErrno
            if let stagedDestinationName {
                var restoreResult: Int32 = -1
                stagedDestinationName.withCString { stagedPointer in
                    destinationString.withCString { destinationPointer in
                        restoreResult = renameatx_np(
                            toDir.fileDescriptor,
                            stagedPointer,
                            toDir.fileDescriptor,
                            destinationPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard restoreResult == 0 else {
                    Logger.passthroughfs.fault("\(#function): Failed to restore the destination after a local rename failure")
                    return replyHandler(nil, POSIXError(.EIO))
                }
            }
            return replyHandler(nil, renameError)
        }

        let newRemotePath = toDir.relativePath.isEmpty
            ? destinationString
            : "\(toDir.relativePath)/\(destinationString)"
        if (fromItem.itemType == .file || fromItem.itemType == .directory),
           !fromItem.isDeltaControlItem {
            do {
                try remoteClient.rename(path: oldRemotePath, to: newRemotePath)
            } catch let remoteError {
                var sourceRollbackResult: Int32 = -1
                destinationString.withCString { destinationPointer in
                    sourceString.withCString { sourcePointer in
                        sourceRollbackResult = renameatx_np(
                            toDir.fileDescriptor,
                            destinationPointer,
                            fromDir.fileDescriptor,
                            sourcePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                var destinationRollbackResult: Int32 = 0
                if let stagedDestinationName {
                    destinationRollbackResult = -1
                    stagedDestinationName.withCString { stagedPointer in
                        destinationString.withCString { destinationPointer in
                            destinationRollbackResult = renameatx_np(
                                toDir.fileDescriptor,
                                stagedPointer,
                                toDir.fileDescriptor,
                                destinationPointer,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                }
                guard sourceRollbackResult == 0, destinationRollbackResult == 0 else {
                    Logger.passthroughfs.fault("\(#function): Failed to restore the local namespace after a remote rename failure")
                    return replyHandler(nil, POSIXError(.EIO))
                }
                return replyHandler(nil, remoteError)
            }
        }

        if let stagedDestinationName {
            var cleanupResult: Int32 = -1
            stagedDestinationName.withCString { stagedPointer in
                cleanupResult = unlinkat(
                    toDir.fileDescriptor,
                    stagedPointer,
                    replacedItemType == .directory ? AT_REMOVEDIR : 0
                )
            }
            if cleanupResult != 0 {
                Logger.passthroughfs.error("\(#function): A hidden replaced placeholder could not be reclaimed: \(posixErrno)")
            }
        }

        self.itemCacheQueue.sync {
            fromItem.name = destinationString
            fromItem.parent = toDir
            self.itemCache.removeValue(forKey: fromItemInode)
            self.itemCache[fromItem.inode] = fromItem
            if let replacedItem, replacedItem !== fromItem {
                replacedItem.isDeleted = true
            }
        }
        return replyHandler(destinationName, nil)
    }

    /// Performs an enumeration of the contents of a directory.
    /// - Parameters:
    ///   - directory: The directory to enumerate.
    ///   - cookie: The cookie returned by a previous call to enumerateDirectory().
    ///   - verifier: The directory verifier.
    ///   - attributes: The attributes to request for each item in the directory.
    ///   - packer: The packer to use to serialize directory entries.
    ///   - replyHandler: The handler to call when the enumeration is complete.
    public func enumerateDirectory(_ directory: FSItem,
                                   startingAt cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier,
                                   attributes: FSItem.GetAttributesRequest?,
                                   packer: FSDirectoryEntryPacker,
                                   replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast directory")
            return replyHandler(FSDirectoryVerifier(0), POSIXError(.EINVAL))
        }

        if dirItem.itemType != .directory {
            Logger.passthroughfs.error("\(#function): given item isn't a directory")
            return replyHandler(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }
        operationLock.lock()
        defer { operationLock.unlock() }

        let oldFD = dirItem.fileDescriptor
        if oldFD == -1 {
            do {
                try dirItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                return replyHandler(FSDirectoryVerifier(0), error)
            }
        }
        defer {
            if oldFD == -1 {
                try? dirItem.closeItem()
            }
        }

        let duplicate = Darwin.fcntl(dirItem.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            return replyHandler(FSDirectoryVerifier(0), posixErrno)
        }
        guard let dirp = fdopendir(duplicate) else {
            let openError = posixErrno
            _ = Darwin.close(duplicate)
            return replyHandler(FSDirectoryVerifier(0), openError)
        }
        defer { _ = closedir(dirp) }
        let currentVerifier: FSDirectoryVerifier
        do {
            currentVerifier = try self.directoryVerifier(descriptor: dirItem.fileDescriptor)
        } catch {
            return replyHandler(FSDirectoryVerifier(0), error)
        }
        if cookie.rawValue == 0 {
            rewinddir(dirp)
        } else {
            guard
                verifier == currentVerifier,
                let cookieValue = Int(exactly: cookie.rawValue)
            else {
                return replyHandler(currentVerifier, FSError(.invalidDirectoryCookie))
            }
            seekdir(dirp, cookieValue)
        }

        var enumerationError: Error?
        while true {
            errno = 0
            guard let safeDirent = readdir(dirp) else {
                if errno != 0 { enumerationError = posixErrno }
                break
            }

            // Extract the filename from the C structure.
            let filename = withUnsafePointer(to: &safeDirent.pointee.d_name) { namePtr -> String? in
                let nameLength = Int(safeDirent.pointee.d_namlen)
                let capacity = max(nameLength, 1)
                return namePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { arrayPtr in
                    String(bytes: UnsafeBufferPointer(start: arrayPtr, count: nameLength), encoding: .utf8)
                }
            }
            guard let filename else {
                return replyHandler(currentVerifier, POSIXError(.EILSEQ))
            }

            if filename.hasPrefix(".delta-")
                || (attributes != nil && (filename == "." || filename == "..")) {
                continue
            }

            let entryItemType: FSItem.ItemType
            switch safeDirent.pointee.d_type {
            case UInt8(DT_DIR):
                entryItemType = .directory
            case UInt8(DT_LNK):
                return replyHandler(currentVerifier, POSIXError(.ENOTSUP))
            case UInt8(DT_REG):
                var entryStatus = stat()
                guard fstatat(
                    dirItem.fileDescriptor,
                    filename,
                    &entryStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    return replyHandler(currentVerifier, posixErrno)
                }
                guard
                    (entryStatus.st_mode & S_IFMT) == S_IFREG,
                    entryStatus.st_nlink == 1
                else {
                    return replyHandler(currentVerifier, POSIXError(.ESTALE))
                }
                entryItemType = .file
            case UInt8(DT_UNKNOWN):
                var entryStatus = stat()
                guard fstatat(
                    dirItem.fileDescriptor,
                    filename,
                    &entryStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    return replyHandler(currentVerifier, posixErrno)
                }
                guard let discoveredType = fsItemType(
                    forPOSIXMode: entryStatus.st_mode
                ) else {
                    return replyHandler(currentVerifier, POSIXError(.ENOTSUP))
                }
                guard discoveredType != .file || entryStatus.st_nlink == 1 else {
                    return replyHandler(currentVerifier, POSIXError(.ESTALE))
                }
                entryItemType = discoveredType
            default:
                return replyHandler(currentVerifier, POSIXError(.ENOTSUP))
            }
            let itemID = safeDirent.pointee.d_ino
            let nextCookie = telldir(dirp)
            guard nextCookie >= 0 else {
                return replyHandler(currentVerifier, posixErrno)
            }
            var itemAttributes: FSItem.Attributes? = nil
            if attributes != nil {
                var attributeError: Error?
                self.lookupItem(named: FSFileName(string: filename), inDirectory: dirItem) { lookupItem, itemName, error in
                    guard let lookupItem, error == nil else {
                        attributeError = error ?? POSIXError(.EIO)
                        return
                    }
                    self.getAttributes(attributes!, of: lookupItem) { innerItemAttributes, innerError in
                        itemAttributes = innerItemAttributes
                        attributeError = innerError
                    }
                }
                if let attributeError {
                    return replyHandler(currentVerifier, attributeError)
                }
            }
            let packerRes = packer.packEntry(name: FSFileName(string: filename),
                                             itemType: entryItemType,
                                             itemID: FSItem.Identifier(rawValue: itemID) ?? FSItem.Identifier.invalid,
                                             nextCookie: FSDirectoryCookie(UInt64(nextCookie)),
                                             attributes: itemAttributes)
            if packerRes == false {
                break
            }
        }
        if let enumerationError {
            return replyHandler(currentVerifier, enumerationError)
        }
        do {
            let finalVerifier = try self.directoryVerifier(descriptor: dirItem.fileDescriptor)
            guard finalVerifier == currentVerifier else {
                return replyHandler(finalVerifier, FSError(.invalidDirectoryCookie))
            }
        } catch {
            return replyHandler(currentVerifier, error)
        }
        return replyHandler(currentVerifier, nil)
    }

    private func directoryVerifier(descriptor: Int32) throws -> FSDirectoryVerifier {
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else {
            throw posixErrno
        }
        var value = UInt64(attributes.st_ino)
        value ^= UInt64(bitPattern: Int64(attributes.st_mtimespec.tv_sec)) &* 0x9E37_79B1_85EB_CA87
        value ^= UInt64(bitPattern: Int64(attributes.st_mtimespec.tv_nsec)) &* 0xC2B2_AE3D_27D4_EB4F
        value ^= UInt64(bitPattern: Int64(attributes.st_ctimespec.tv_sec)) &* 0x1656_67B1_9E37_79F9
        value ^= UInt64(bitPattern: Int64(attributes.st_ctimespec.tv_nsec)) &* 0x85EB_CA77_C2B2_AE63
        value ^= UInt64(bitPattern: Int64(attributes.st_size))
        return FSDirectoryVerifier(value == 0 ? 1 : value)
    }

    /// The staged replacement is no longer reachable through its public name,
    /// so checking it here preserves native rename semantics without racing a
    /// second FSKit namespace operation. Directory replacement is valid only
    /// when both items are directories and the destination is empty.
    private func directoryIsEmpty(
        named name: String,
        in parentDescriptor: Int32,
        expectedInode: UInt64?
    ) throws -> Bool {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixErrno }
        var attributes = stat()
        guard
            Darwin.fstat(descriptor, &attributes) == 0,
            (attributes.st_mode & S_IFMT) == S_IFDIR,
            expectedInode == nil || attributes.st_ino == expectedInode
        else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.ESTALE)
        }
        guard let directory = fdopendir(descriptor) else {
            let openError = posixErrno
            _ = Darwin.close(descriptor)
            throw openError
        }
        defer { _ = closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            var rawName = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: rawName)
            let entryName = withUnsafePointer(to: &rawName) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let entryName else { throw POSIXError(.EILSEQ) }
            if entryName != "." && entryName != ".." {
                return false
            }
            errno = 0
        }
        guard errno == 0 else { throw posixErrno }
        return true
    }

    /// Returns `true` if the volume supports the specified capability, otherwise returns `false`.
    /// - Parameter capability: The capability to check.
    private func volumeSupportsCapability(capability: Int32) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = UInt32(ATTR_VOL_CAPABILITIES)

        let lenSize = MemoryLayout<UInt32>.size
        let size = lenSize + MemoryLayout<vol_capabilities_attr_t>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
        defer { buffer.deallocate() }
        if fgetattrlist(self.rootItem.fileDescriptor, &attrs, buffer, size, 0) == -1 {
            return false
        }

        let attrPtr = (buffer + lenSize).assumingMemoryBound(to: vol_capabilities_attr_t.self)
        let validClone = (attrPtr.pointee.valid.1 & UInt32(capability)) != 0
        let capClone = (attrPtr.pointee.capabilities.1 & UInt32(capability)) != 0
        return validClone && capClone
    }

    /// The set of volume capabilities supported by this instance.
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsSymbolicLinks                  = false
        capabilities.supportsHardLinks                      = false
        capabilities.supportsHiddenFiles                    = true
        capabilities.supportsPersistentObjectIDs            = false
        capabilities.supportsJournal                        = false
        capabilities.supportsActiveJournal                  = false
        capabilities.supportsSparseFiles                    = true
        capabilities.supportsZeroRuns                       = false
        // statfs crosses authenticated IPC and walks the bounded sparse-file
        // map, so upper layers must remain free to cache it.
        capabilities.supportsFastStatFS                     = false
        capabilities.supports2TBFiles                       = true
        capabilities.supportsOpenDenyModes                  = false
        capabilities.supports64BitObjectIDs                 = true
        capabilities.supportsDocumentID                     = false
        capabilities.supportsSharedSpace                    = false
        capabilities.supportsVolumeGroups                   = false
        capabilities.doesNotSupportVolumeSizes              = false
        capabilities.doesNotSupportImmutableFiles           = true
        capabilities.doesNotSupportRootTimes                = false
        capabilities.doesNotSupportSettingFilePermissions   = false
        // Determine caseSensitivity:
        if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_SENSITIVE) {
            capabilities.caseFormat = FSVolume.CaseFormat.sensitive
        } else if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_PRESERVING) {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitiveCasePreserving
        } else {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitive
        }
        return capabilities
    }

}
