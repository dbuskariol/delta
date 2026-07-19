import CryptoKit
import Darwin
import Foundation

public enum TimeMachineSparseFileSessionError: Error, Equatable, LocalizedError {
    case invalidPath(String)
    case invalidRange
    case cacheLimitExceeded(requiredBytes: Int64, limitBytes: Int64)
    case commitNotPrepared
    case invalidRename
    case renameDestinationNotEmpty
    case unexpectedCommittedGeneration

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            "The sparse Time Machine file path is invalid: \(path)."
        case .invalidRange:
            "The sparse Time Machine read or write range is invalid."
        case let .cacheLimitExceeded(requiredBytes, limitBytes):
            "Time Machine needs \(requiredBytes) bytes of dirty cache, exceeding Delta's \(limitBytes)-byte cache limit. Remote storage must catch up before more data can be accepted."
        case .commitNotPrepared:
            "No matching Time Machine generation is waiting to be committed."
        case .invalidRename:
            "A Time Machine directory cannot be moved inside itself."
        case .renameDestinationNotEmpty:
            "The remote Time Machine directory rename would replace an existing non-empty directory."
        case .unexpectedCommittedGeneration:
            "The committed Time Machine generation does not match the pending local generation."
        }
    }
}

public struct TimeMachineSparseFileCacheUsage: Equatable, Sendable {
    public var cleanBytes: Int64
    public var dirtyBytes: Int64
    public var limitBytes: Int64

    public init(cleanBytes: Int64, dirtyBytes: Int64, limitBytes: Int64) {
        self.cleanBytes = cleanBytes
        self.dirtyBytes = dirtyBytes
        self.limitBytes = limitBytes
    }

    public var totalBytes: Int64 {
        let (total, overflow) = cleanBytes.addingReportingOverflow(dirtyBytes)
        return overflow ? Int64.max : total
    }
}

public enum TimeMachineSparseFileCommitReconciliation: Equatable, Sendable {
    case complete
    case cacheCleanupDeferred
}

struct TimeMachineDirtyCacheSpill: Sendable {
    struct Entry: Sendable {
        var path: String
        var index: UInt64
        var cacheURL: URL
        var reference: TimeMachineChunkReference
    }

    var entries: [Entry]
    var objectsByDigest: [String: TimeMachineObjectPayload]
}

public final class TimeMachineSparseFileSession: @unchecked Sendable {
    public typealias RemoteChunkLoader = @Sendable (TimeMachineChunkReference) throws -> Data
    public typealias ReusingRemoteChunkLoader = @Sendable (
        TimeMachineChunkReference,
        inout Data
    ) throws -> Void

    private struct ChunkKey: Hashable {
        var path: String
        var index: UInt64
    }

    private struct FileState {
        var logicalSize: UInt64
        var committedChunks: [UInt64: TimeMachineChunkReference]
    }

    private let lock = NSRecursiveLock()
    private let cacheURL: URL
    private let cleanCacheURL: URL
    private let dirtyCacheURL: URL
    private let storeID: UUID
    private let writerID: UUID
    private let cacheLimitBytes: Int64
    private let chunkSize: Int
    private let zeroChunk: Data
    private var head: TimeMachineGenerationHead?
    private var files: [String: FileState]
    private var dirtyChunks: [ChunkKey: URL]
    private var metadataIsDirty: Bool
    private var pendingCommit: TimeMachineGenerationCommit?
    private var pendingFiles: [TimeMachineRemoteFile]?
    private var cacheMaintenanceWarning: String?
    private var cacheMaintenanceWarningWasReported: Bool
    /// DiskImages performs hundreds of small, repeated reads inside the same
    /// sparsebundle bands while attaching APFS. Keep only the two most recent
    /// already-authenticated chunks in memory so those reads do not reread and
    /// hash an entire 8 MiB cache file each time. This fixed 16 MiB ceiling is
    /// independent of image and user-selected cache size.
    private var hotCleanChunks: [(key: ChunkKey, digest: String, data: Data)]

    public init(
        cacheURL: URL,
        storeID: UUID,
        writerID: UUID,
        cacheLimitBytes: Int64,
        chunkSize: Int = TimeMachineRepositorySettings.chunkSizeBytes,
        head: TimeMachineGenerationHead? = nil,
        remoteFiles: [TimeMachineRemoteFile] = [],
        fileManager: FileManager = .default
    ) throws {
        guard chunkSize > 0, cacheLimitBytes >= Int64(chunkSize) else {
            throw TimeMachineSparseFileSessionError.invalidRange
        }
        self.cacheURL = cacheURL.standardizedFileURL
        self.cleanCacheURL = self.cacheURL.appendingPathComponent("clean", isDirectory: true)
        self.dirtyCacheURL = self.cacheURL.appendingPathComponent("dirty", isDirectory: true)
        self.storeID = storeID
        self.writerID = writerID
        self.cacheLimitBytes = cacheLimitBytes
        self.chunkSize = chunkSize
        self.zeroChunk = Data(repeating: 0, count: chunkSize)
        self.head = head
        self.files = [:]
        self.dirtyChunks = [:]
        self.metadataIsDirty = false
        self.pendingCommit = nil
        self.pendingFiles = nil
        self.cacheMaintenanceWarning = nil
        self.cacheMaintenanceWarningWasReported = false
        self.hotCleanChunks = []

        try Self.preparePrivateCacheDirectories(
            cacheURL: self.cacheURL,
            cleanCacheURL: self.cleanCacheURL,
            dirtyCacheURL: self.dirtyCacheURL,
            fileManager: fileManager
        )

        if let manifest = head?.signedManifest.manifest {
            guard manifest.storeID == storeID else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            files = Dictionary(uniqueKeysWithValues: remoteFiles.map { file in
                (
                    file.path,
                    FileState(
                        logicalSize: file.logicalSize,
                        committedChunks: Dictionary(uniqueKeysWithValues: file.chunks.map { ($0.index, $0) })
                    )
                )
            })
        }
        try evictCleanCacheIfNeeded(reserving: 0, fileManager: fileManager)
    }

    public func read(
        path: String,
        offset: UInt64,
        length: Int,
        remoteLoader: RemoteChunkLoader
    ) throws -> Data {
        try read(
            path: path,
            offset: offset,
            length: length,
            reusingRemoteLoader: { reference, buffer in
                buffer = try remoteLoader(reference)
            }
        )
    }

    public func read(
        path: String,
        offset: UInt64,
        length: Int,
        reusingRemoteLoader: ReusingRemoteChunkLoader
    ) throws -> Data {
        try lock.withLock {
            let path = try validatedPath(path)
            guard length >= 0 else {
                throw TimeMachineSparseFileSessionError.invalidRange
            }
            guard length > 0, let file = files[path], offset < file.logicalSize else {
                return Data()
            }
            let available = min(UInt64(length), file.logicalSize - offset)
            var output = Data(capacity: Int(available))
            var cursor = offset
            let end = offset + available
            while cursor < end {
                let index = cursor / UInt64(chunkSize)
                let chunkOffset = Int(cursor % UInt64(chunkSize))
                let count = min(Int(end - cursor), chunkSize - chunkOffset)
                let chunk = try chunkData(
                    path: path,
                    index: index,
                    remoteLoader: reusingRemoteLoader
                )
                if chunkOffset < chunk.count {
                    let readable = min(count, chunk.count - chunkOffset)
                    output.append(chunk.subdata(in: chunkOffset..<(chunkOffset + readable)))
                    if readable < count {
                        output.append(Data(repeating: 0, count: count - readable))
                    }
                } else {
                    output.append(Data(repeating: 0, count: count))
                }
                cursor += UInt64(count)
            }
            return output
        }
    }

    public func write(
        path: String,
        offset: UInt64,
        data: Data,
        remoteLoader: RemoteChunkLoader
    ) throws {
        try write(
            path: path,
            offset: offset,
            data: data,
            reusingRemoteLoader: { reference, buffer in
                buffer = try remoteLoader(reference)
            }
        )
    }

    public func write(
        path: String,
        offset: UInt64,
        data: Data,
        reusingRemoteLoader: ReusingRemoteChunkLoader
    ) throws {
        try lock.withLock {
            let path = try validatedPath(path)
            guard !data.isEmpty else { return }
            guard offset <= UInt64.max - UInt64(data.count) else {
                throw TimeMachineSparseFileSessionError.invalidRange
            }

            var file = files[path] ?? FileState(logicalSize: 0, committedChunks: [:])
            var stagedChunks: [ChunkKey: Data] = [:]
            var priorDirtyChunks: [ChunkKey: Data] = [:]
            var dataOffset = 0
            while dataOffset < data.count {
                let logicalOffset = offset + UInt64(dataOffset)
                let index = logicalOffset / UInt64(chunkSize)
                let chunkOffset = Int(logicalOffset % UInt64(chunkSize))
                let count = min(data.count - dataOffset, chunkSize - chunkOffset)
                let key = ChunkKey(path: path, index: index)
                let existingChunk = try stagedChunks[key]
                    ?? chunkData(
                        path: path,
                        index: index,
                        remoteLoader: reusingRemoteLoader
                    )
                var chunk = existingChunk
                if priorDirtyChunks[key] == nil, let dirtyURL = dirtyChunks[key] {
                    priorDirtyChunks[key] = try TimeMachineBoundedRegularFile.read(
                        at: dirtyURL,
                        maximumBytes: chunkSize
                    )
                }
                if chunk.count < chunkSize {
                    chunk.append(Data(repeating: 0, count: chunkSize - chunk.count))
                }
                chunk.replaceSubrange(
                    chunkOffset..<(chunkOffset + count),
                    with: data[dataOffset..<(dataOffset + count)]
                )
                stagedChunks[key] = chunk
                dataOffset += count
            }
            try installDirtyChunksAtomically(stagedChunks, priorDirtyChunks: priorDirtyChunks)
            file.logicalSize = max(file.logicalSize, offset + UInt64(data.count))
            files[path] = file
            metadataIsDirty = true
            pendingCommit = nil
        }
    }

    public func truncate(
        path: String,
        size: UInt64,
        remoteLoader: RemoteChunkLoader
    ) throws {
        try truncate(
            path: path,
            size: size,
            reusingRemoteLoader: { reference, buffer in
                buffer = try remoteLoader(reference)
            }
        )
    }

    public func truncate(
        path: String,
        size: UInt64,
        reusingRemoteLoader: ReusingRemoteChunkLoader
    ) throws {
        try lock.withLock {
            let path = try validatedPath(path)
            var file = files[path] ?? FileState(logicalSize: 0, committedChunks: [:])
            if size < file.logicalSize {
                let firstRemovedIndex = (size + UInt64(chunkSize) - 1) / UInt64(chunkSize)
                for index in Array(file.committedChunks.keys) where index >= firstRemovedIndex {
                    file.committedChunks.removeValue(forKey: index)
                }
                let retainedByteCount = Int(size % UInt64(chunkSize))
                if retainedByteCount > 0 {
                    let retainedIndex = size / UInt64(chunkSize)
                    var chunk = try chunkData(
                        path: path,
                        index: retainedIndex,
                        remoteLoader: reusingRemoteLoader
                    )
                    if chunk.count > retainedByteCount {
                        chunk.removeSubrange(retainedByteCount..<chunk.count)
                        try storeDirtyChunk(chunk, key: ChunkKey(path: path, index: retainedIndex))
                    }
                }
                for key in Array(dirtyChunks.keys) where key.path == path && key.index >= firstRemovedIndex {
                    if let url = dirtyChunks.removeValue(forKey: key) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            file.logicalSize = size
            files[path] = file
            metadataIsDirty = true
            pendingCommit = nil
        }
    }

    public func remove(path: String) throws {
        try lock.withLock {
            let path = try validatedPath(path)
            files.removeValue(forKey: path)
            for key in Array(dirtyChunks.keys) where key.path == path {
                if let url = dirtyChunks.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            metadataIsDirty = true
            pendingCommit = nil
        }
    }

    public func create(path: String) throws {
        try lock.withLock {
            let path = try validatedPath(path)
            if files[path] == nil {
                files[path] = FileState(logicalSize: 0, committedChunks: [:])
                metadataIsDirty = true
                pendingCommit = nil
            }
        }
    }

    public func rename(path: String, to newPath: String) throws {
        try lock.withLock {
            let path = try validatedPath(path)
            let newPath = try validatedPath(newPath)
            guard path != newPath else {
                return
            }

            let pathMappings: [(old: String, new: String)]
            let isDirectoryRename: Bool
            if files[path] != nil {
                pathMappings = [(path, newPath)]
                isDirectoryRename = false
            } else {
                let sourcePrefix = "\(path)/"
                let destinationPrefix = "\(newPath)/"
                guard !newPath.hasPrefix(sourcePrefix) else {
                    throw TimeMachineSparseFileSessionError.invalidRename
                }
                let sourcePaths = files.keys
                    .filter { $0.hasPrefix(sourcePrefix) }
                    .sorted()
                guard !sourcePaths.isEmpty else { return }
                pathMappings = sourcePaths.map { sourcePath in
                    (
                        sourcePath,
                        destinationPrefix + sourcePath.dropFirst(sourcePrefix.count)
                    )
                }
                isDirectoryRename = true
            }

            let sourcePaths = Set(pathMappings.map(\.old))
            let destinationPaths = Set(pathMappings.map(\.new))
            guard destinationPaths.count == pathMappings.count else {
                throw TimeMachineSparseFileSessionError.renameDestinationNotEmpty
            }
            if isDirectoryRename {
                let destinationPrefix = "\(newPath)/"
                let hasUnrelatedDestinationContent = files.keys.contains { existingPath in
                    (existingPath == newPath || existingPath.hasPrefix(destinationPrefix))
                        && !sourcePaths.contains(existingPath)
                }
                guard !hasUnrelatedDestinationContent else {
                    throw TimeMachineSparseFileSessionError.renameDestinationNotEmpty
                }
            }

            let sourceStates = Dictionary(uniqueKeysWithValues: pathMappings.compactMap { mapping in
                files[mapping.old].map { (mapping.old, $0) }
            })
            guard sourceStates.count == pathMappings.count else { return }
            let destinationBySource = Dictionary(
                uniqueKeysWithValues: pathMappings.map { ($0.old, $0.new) }
            )
            var renamedDirtyChunks: [(
                old: ChunkKey,
                new: ChunkKey,
                oldURL: URL,
                newURL: URL,
                replacedDestination: Bool
            )] = []
            for key in dirtyChunks.keys.sorted(by: {
                $0.path == $1.path ? $0.index < $1.index : $0.path < $1.path
            }) {
                guard let destinationPath = destinationBySource[key.path] else { continue }
                guard let url = dirtyChunks[key] else { continue }
                _ = try validatedCacheEntryAttributes(at: url)
                let newKey = ChunkKey(path: destinationPath, index: key.index)
                let destination = dirtyURL(for: newKey)
                let trackedDestination = dirtyChunks[newKey] != nil
                var destinationAttributes = stat()
                let destinationLookup = Darwin.lstat(
                    destination.path,
                    &destinationAttributes
                )
                if destinationLookup != 0, errno != ENOENT {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                guard (destinationLookup == 0) == trackedDestination else {
                    throw POSIXError(.EPERM)
                }
                if trackedDestination {
                    _ = try validatedCacheEntryAttributes(at: destination)
                }
                renamedDirtyChunks.append(
                    (
                        key,
                        newKey,
                        url,
                        destination,
                        trackedDestination
                    )
                )
            }
            var installed: [(
                old: ChunkKey,
                new: ChunkKey,
                oldURL: URL,
                newURL: URL,
                replacedDestination: Bool
            )] = []
            do {
                for renamed in renamedDirtyChunks {
                    let result = if renamed.replacedDestination {
                        Darwin.renameatx_np(
                            AT_FDCWD,
                            renamed.oldURL.path,
                            AT_FDCWD,
                            renamed.newURL.path,
                            UInt32(RENAME_SWAP)
                        )
                    } else {
                        Darwin.rename(renamed.oldURL.path, renamed.newURL.path)
                    }
                    guard result == 0 else {
                        throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                    }
                    installed.append(renamed)
                }
            } catch {
                for renamed in installed.reversed() {
                    if renamed.replacedDestination {
                        _ = Darwin.renameatx_np(
                            AT_FDCWD,
                            renamed.newURL.path,
                            AT_FDCWD,
                            renamed.oldURL.path,
                            UInt32(RENAME_SWAP)
                        )
                    } else {
                        _ = Darwin.rename(
                            renamed.newURL.path,
                            renamed.oldURL.path
                        )
                    }
                }
                throw error
            }

            let sourceKeys = Set(renamedDirtyChunks.map(\.old))
            let renamedDestinationKeys = Set(renamedDirtyChunks.map(\.new))
            let destinationKeys = dirtyChunks.keys.filter {
                destinationPaths.contains($0.path)
            }
            for key in sourceKeys { dirtyChunks.removeValue(forKey: key) }
            for key in destinationKeys where !renamedDestinationKeys.contains(key) {
                if let url = dirtyChunks.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            for renamed in renamedDirtyChunks { dirtyChunks[renamed.new] = renamed.newURL }
            for renamed in renamedDirtyChunks where renamed.replacedDestination {
                if Darwin.unlink(renamed.oldURL.path) != 0, errno != ENOENT {
                    cacheMaintenanceWarning = "Delta could not reclaim obsolete bounded Time Machine cache data. No remote backup data was lost; disconnect and reconnect the disk before more data is accepted."
                    cacheMaintenanceWarningWasReported = false
                }
            }
            for sourcePath in sourcePaths {
                files.removeValue(forKey: sourcePath)
            }
            for destinationPath in destinationPaths {
                files.removeValue(forKey: destinationPath)
            }
            for mapping in pathMappings {
                files[mapping.new] = sourceStates[mapping.old]
            }
            metadataIsDirty = true
            pendingCommit = nil
        }
    }

    public func prepareCommit(createdAt: Date = Date()) throws -> TimeMachineGenerationCommit? {
        try lock.withLock {
            guard metadataIsDirty || !dirtyChunks.isEmpty else {
                return nil
            }
            let generation = (head?.signedManifest.manifest.generation ?? 0) + 1
            var objectsByDigest: [String: TimeMachineObjectPayload] = [:]
            var manifestFiles: [TimeMachineRemoteFile] = []

            for path in files.keys.sorted() {
                guard var state = files[path] else { continue }
                for key in dirtyChunks.keys.filter({ $0.path == path }).sorted(by: { $0.index < $1.index }) {
                    guard let url = dirtyChunks[key] else { continue }
                    let dataCount = try TimeMachineBoundedRegularFile.byteCount(
                        at: url,
                        maximumBytes: chunkSize
                    )
                    let digest = try TimeMachineGenerationStore.sha256Hex(fileAt: url)
                    let reference = TimeMachineChunkReference(
                        index: key.index,
                        objectDigest: digest,
                        byteCount: dataCount
                    )
                    let authenticatedReference = state.committedChunks[key.index]
                    state.committedChunks[key.index] = reference
                    // DiskImages commonly rewrites an existing band with
                    // bytes identical to the authenticated remote object
                    // during attach and metadata housekeeping. The unchanged
                    // shard continues to reference that already-durable
                    // object, so supplying the local duplicate would be both
                    // redundant and outside the changed-object commit set.
                    // Keep the dirty entry until the synchronization
                    // generation is accepted so normal commit reconciliation
                    // still reclaims the bounded local payload.
                    if authenticatedReference != reference {
                        objectsByDigest[digest] = .file(url)
                    }
                }
                let maximumIndex = state.logicalSize == 0
                    ? nil
                    : (state.logicalSize - 1) / UInt64(chunkSize)
                let chunks = state.committedChunks.values
                    .filter { reference in maximumIndex.map { reference.index <= $0 } ?? false }
                    .sorted { $0.index < $1.index }
                manifestFiles.append(
                    TimeMachineRemoteFile(path: path, logicalSize: state.logicalSize, chunks: chunks)
                )
            }

            let manifest = TimeMachineGenerationManifest(
                storeID: storeID,
                generation: generation,
                parentManifestDigest: head?.signedManifest.manifestDigest,
                writerID: writerID,
                createdAt: createdAt,
                fileShards: []
            )
            let existingShardDigests = Set(
                head?.signedManifest.manifest.fileShards.map(\.objectDigest) ?? []
            )
            let shards = try TimeMachineGenerationStore.makeFileShards(
                storeID: storeID,
                files: manifestFiles,
                excludingObjectDigests: existingShardDigests
            )
            var shardedManifest = manifest
            shardedManifest.fileShards = shards.references
            for (digest, data) in shards.objectsByDigest {
                objectsByDigest[digest] = .data(data)
            }
            let commit = TimeMachineGenerationCommit(
                manifest: shardedManifest,
                objectsByDigest: objectsByDigest
            )
            pendingCommit = commit
            pendingFiles = manifestFiles
            return commit
        }
    }

    /// Prepares the current dirty working set for an immutable remote upload
    /// without changing the session or publishing a generation. The caller
    /// must durably stage and verify every returned object before accepting
    /// the spill below.
    func prepareDirtyCacheSpill(
        maximumBytes: Int64 = TimeMachineRepositorySettings.remoteSpillBatchBytes
    ) throws -> TimeMachineDirtyCacheSpill? {
        try lock.withLock {
            guard !dirtyChunks.isEmpty, maximumBytes >= Int64(chunkSize) else {
                return nil
            }
            var entries: [TimeMachineDirtyCacheSpill.Entry] = []
            var objectsByDigest: [String: TimeMachineObjectPayload] = [:]
            var selectedBytes: Int64 = 0
            for key in dirtyChunks.keys.sorted(by: {
                $0.path == $1.path ? $0.index < $1.index : $0.path < $1.path
            }) {
                guard let url = dirtyChunks[key] else { continue }
                let byteCount = try TimeMachineBoundedRegularFile.byteCount(
                    at: url,
                    maximumBytes: chunkSize
                )
                let (nextBytes, overflowed) = selectedBytes.addingReportingOverflow(
                    Int64(byteCount)
                )
                guard !overflowed else {
                    throw TimeMachineSparseFileSessionError.invalidRange
                }
                if !entries.isEmpty, nextBytes > maximumBytes {
                    break
                }
                let digest = try TimeMachineGenerationStore.sha256Hex(fileAt: url)
                entries.append(
                    TimeMachineDirtyCacheSpill.Entry(
                        path: key.path,
                        index: key.index,
                        cacheURL: url,
                        reference: TimeMachineChunkReference(
                            index: key.index,
                            objectDigest: digest,
                            byteCount: byteCount
                        )
                    )
                )
                objectsByDigest[digest] = .file(url)
                selectedBytes = nextBytes
            }
            guard !entries.isEmpty else { return nil }
            return TimeMachineDirtyCacheSpill(
                entries: entries,
                objectsByDigest: objectsByDigest
            )
        }
    }

    /// Replaces locally dirty payloads with references to objects the caller
    /// has already uploaded and read-back verified. Metadata stays dirty and
    /// the authenticated head does not move; a crash before the next sync
    /// therefore restores the previous generation and leaves only reclaimable
    /// unreferenced remote objects.
    @discardableResult
    func acceptDirtyCacheSpill(_ spill: TimeMachineDirtyCacheSpill) throws -> Int {
        try lock.withLock {
            guard !spill.entries.isEmpty else { return 0 }

            // Revalidate the complete set before removing a byte. This catches
            // a substituted or concurrently changed cache entry even though
            // the remote upload itself is content-addressed.
            for entry in spill.entries {
                let key = ChunkKey(path: entry.path, index: entry.index)
                guard
                    dirtyChunks[key] == entry.cacheURL,
                    files[entry.path] != nil,
                    try TimeMachineBoundedRegularFile.byteCount(
                        at: entry.cacheURL,
                        maximumBytes: chunkSize
                    ) == entry.reference.byteCount,
                    try TimeMachineGenerationStore.sha256Hex(fileAt: entry.cacheURL)
                        == entry.reference.objectDigest
                else {
                    throw POSIXError(.EPERM)
                }
            }

            var acceptedCount = 0
            for entry in spill.entries {
                let key = ChunkKey(path: entry.path, index: entry.index)
                guard var state = files[entry.path] else {
                    throw POSIXError(.EPERM)
                }
                state.committedChunks[entry.index] = entry.reference
                files[entry.path] = state
                do {
                    try FileManager.default.removeItem(at: entry.cacheURL)
                } catch {
                    // Keep this entry tracked as dirty so a later commit still
                    // supplies its verified bytes instead of trusting a local
                    // cleanup that did not complete.
                    throw error
                }
                dirtyChunks.removeValue(forKey: key)
                acceptedCount += 1
            }
            pendingCommit = nil
            pendingFiles = nil
            metadataIsDirty = true
            return acceptedCount
        }
    }

    @discardableResult
    public func acceptCommittedHead(
        _ committedHead: TimeMachineGenerationHead
    ) throws -> TimeMachineSparseFileCommitReconciliation {
        try lock.withLock {
            guard let pendingCommit, let pendingFiles else {
                throw TimeMachineSparseFileSessionError.commitNotPrepared
            }
            guard
                pendingCommit.manifest == committedHead.signedManifest.manifest,
                committedHead.signedManifest.manifest.generation == (head?.signedManifest.manifest.generation ?? 0) + 1
            else {
                throw TimeMachineSparseFileSessionError.unexpectedCommittedGeneration
            }

            let committedFiles = Dictionary(uniqueKeysWithValues: pendingFiles.map { file in
                (
                    file.path,
                    FileState(
                        logicalSize: file.logicalSize,
                        committedChunks: Dictionary(uniqueKeysWithValues: file.chunks.map { ($0.index, $0) })
                    )
                )
            })
            let committedDirtyChunks = dirtyChunks
            files = committedFiles
            dirtyChunks.removeAll(keepingCapacity: true)
            head = committedHead
            self.pendingCommit = nil
            self.pendingFiles = nil
            metadataIsDirty = false

            // The authenticated remote generation is authoritative from this
            // point onward. Cache promotion is reconstructible housekeeping:
            // a local failure must not turn a verified remote fsync into a
            // retry of the already-published generation.
            var cleanupWasDeferred = false
            for (key, dirtyURL) in committedDirtyChunks {
                guard
                    let reference = committedFiles[key.path]?.committedChunks[key.index]
                else {
                    do {
                        try FileManager.default.removeItem(at: dirtyURL)
                    } catch {
                        cleanupWasDeferred = true
                    }
                    continue
                }
                let cleanURL = cleanURL(forDigest: reference.objectDigest)
                let validCleanCopy = (try? TimeMachineBoundedRegularFile.read(
                    at: cleanURL,
                    maximumBytes: chunkSize
                )).map {
                    $0.count == reference.byteCount
                        && TimeMachineGenerationStore.sha256Hex($0) == reference.objectDigest
                } ?? false
                if validCleanCopy {
                    do {
                        try FileManager.default.removeItem(at: dirtyURL)
                    } catch {
                        cleanupWasDeferred = true
                    }
                    continue
                }
                if FileManager.default.fileExists(atPath: cleanURL.path) {
                    do {
                        try FileManager.default.removeItem(at: cleanURL)
                    } catch {
                        cleanupWasDeferred = true
                    }
                }
                do {
                    try FileManager.default.moveItem(at: dirtyURL, to: cleanURL)
                } catch {
                    cleanupWasDeferred = true
                    try? FileManager.default.removeItem(at: dirtyURL)
                }
            }
            do {
                try evictCleanCacheIfNeeded(reserving: 0)
            } catch {
                cleanupWasDeferred = true
            }
            return cleanupWasDeferred ? .cacheCleanupDeferred : .complete
        }
    }

    public func cacheUsage() -> TimeMachineSparseFileCacheUsage {
        lock.withLock {
            do {
                return try measuredCacheUsage()
            } catch {
                // FSKit's statfs surface cannot throw. Treat an unmeasurable
                // cache as fully consumed so Time Machine applies backpressure
                // rather than accepting data beyond Delta's configured bound.
                return TimeMachineSparseFileCacheUsage(
                    cleanBytes: 0,
                    dirtyBytes: cacheLimitBytes,
                    limitBytes: cacheLimitBytes
                )
            }
        }
    }

    public func logicalSize(of path: String) -> UInt64? {
        lock.withLock {
            files[path]?.logicalSize
        }
    }

    public func takeCacheMaintenanceWarning() -> String? {
        lock.withLock {
            guard
                !cacheMaintenanceWarningWasReported,
                let cacheMaintenanceWarning
            else {
                return nil
            }
            cacheMaintenanceWarningWasReported = true
            return cacheMaintenanceWarning
        }
    }

    public func usedDataBytes() -> Int64 {
        lock.withLock {
            var committed: Int64 = 0
            for (path, state) in files {
                for (index, reference) in state.committedChunks
                    where dirtyChunks[ChunkKey(path: path, index: index)] == nil {
                    let (next, overflow) = committed.addingReportingOverflow(
                        Int64(reference.byteCount)
                    )
                    if overflow { return Int64.max }
                    committed = next
                }
            }
            guard let dirtyBytes = try? measuredAllocatedBytes(in: dirtyCacheURL) else {
                return Int64.max
            }
            let (total, overflow) = committed.addingReportingOverflow(dirtyBytes)
            return overflow ? Int64.max : total
        }
    }

    private func chunkData(
        path: String,
        index: UInt64,
        remoteLoader: ReusingRemoteChunkLoader
    ) throws -> Data {
        let key = ChunkKey(path: path, index: index)
        if let dirtyURL = dirtyChunks[key] {
            return try TimeMachineBoundedRegularFile.read(
                at: dirtyURL,
                maximumBytes: chunkSize
            )
        }
        guard let reference = files[path]?.committedChunks[index] else {
            return zeroChunk
        }
        if let hotIndex = hotCleanChunks.firstIndex(where: {
            $0.key == key && $0.digest == reference.objectDigest
        }) {
            let hot = hotCleanChunks.remove(at: hotIndex)
            hotCleanChunks.append(hot)
            return hot.data
        }
        let cleanURL = cleanURL(forDigest: reference.objectDigest)
        var reusable = takeReusableCleanChunkBuffer()
        do {
            try TimeMachineBoundedRegularFile.read(
                at: cleanURL,
                maximumBytes: chunkSize,
                touchModificationDate: true,
                into: &reusable
            )
            if reusable.count == reference.byteCount,
               TimeMachineGenerationStore.sha256Hex(reusable) == reference.objectDigest {
                retainHotCleanChunk(reusable, key: key, digest: reference.objectDigest)
                return reusable
            }
        } catch {
            // A missing or invalid reconstructible cache entry falls through to
            // the authenticated remote object. Its allocation remains reusable.
        }

        try remoteLoader(reference, &reusable)
        let digest = TimeMachineGenerationStore.sha256Hex(reusable)
        guard digest == reference.objectDigest, reusable.count == reference.byteCount else {
            throw TimeMachineObjectStoreError.invalidObjectDigest(
                expected: reference.objectDigest,
                actual: digest
            )
        }
        retainHotCleanChunk(reusable, key: key, digest: digest)
        do {
            try evictCleanCacheIfNeeded(reserving: Int64(reusable.count))
            let usage = try measuredCacheUsage()
            let (required, overflow) = usage.totalBytes.addingReportingOverflow(
                Int64(reusable.count)
            )
            if !overflow, required <= cacheLimitBytes {
                try reusable.write(to: cleanURL, options: [.atomic])
            }
        } catch {
            // A clean-cache write is an optimization after the remote object
            // has passed digest and length verification. Preserve the read and
            // surface one coalesced operational warning rather than making the
            // authenticated remote data unavailable.
            if cacheMaintenanceWarning == nil {
                cacheMaintenanceWarning = "Delta could not update its reconstructible Time Machine read cache. Verified remote data remains available."
            }
        }
        return reusable
    }

    private func takeReusableCleanChunkBuffer() -> Data {
        guard hotCleanChunks.count >= 2 else { return Data() }
        return hotCleanChunks.removeFirst().data
    }

    private func retainHotCleanChunk(
        _ data: Data,
        key: ChunkKey,
        digest: String
    ) {
        hotCleanChunks.removeAll { $0.key == key }
        hotCleanChunks.append((key: key, digest: digest, data: data))
        if hotCleanChunks.count > 2 {
            hotCleanChunks.removeFirst(hotCleanChunks.count - 2)
        }
    }

    private func storeDirtyChunk(_ data: Data, key: ChunkKey) throws {
        // Atomic replacement temporarily retains the previous dirty file while
        // writing its successor. Reserve the complete successor, not merely
        // its eventual size delta, so the configured cache limit also bounds
        // transient on-disk allocation.
        try reserveTransientBytes(Int64(data.count))
        let url = dirtyURL(for: key)
        try data.write(to: url, options: [.atomic])
        dirtyChunks[key] = url
    }

    private func installDirtyChunksAtomically(
        _ chunks: [ChunkKey: Data],
        priorDirtyChunks: [ChunkKey: Data]
    ) throws {
        guard !chunks.isEmpty else { return }
        var transientBytes: Int64 = 0
        for chunk in chunks.values {
            let (next, overflow) = transientBytes.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else {
                throw TimeMachineSparseFileSessionError.cacheLimitExceeded(
                    requiredBytes: Int64.max,
                    limitBytes: cacheLimitBytes
                )
            }
            transientBytes = next
        }
        try reserveTransientBytes(transientBytes)

        let stagingURL = dirtyCacheURL.appendingPathComponent(
            ".pending-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        var stagedURLs: [ChunkKey: URL] = [:]
        for (key, chunk) in chunks {
            let url = stagingURL.appendingPathComponent(dirtyURL(for: key).lastPathComponent)
            try chunk.write(to: url, options: [.atomic])
            stagedURLs[key] = url
        }

        var installed: [ChunkKey] = []
        do {
            for key in chunks.keys.sorted(by: {
                $0.path == $1.path ? $0.index < $1.index : $0.path < $1.path
            }) {
                guard let stagedURL = stagedURLs[key] else { continue }
                let destination = dirtyURL(for: key)
                guard Darwin.rename(stagedURL.path, destination.path) == 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
                dirtyChunks[key] = destination
                installed.append(key)
            }
        } catch {
            for key in installed.reversed() {
                let destination = dirtyURL(for: key)
                if let previous = priorDirtyChunks[key] {
                    try? previous.write(to: destination, options: [.atomic])
                    dirtyChunks[key] = destination
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    dirtyChunks.removeValue(forKey: key)
                }
            }
            throw error
        }
    }

    private func reserveTransientBytes(_ bytes: Int64) throws {
        guard bytes >= 0 else {
            throw TimeMachineSparseFileSessionError.invalidRange
        }
        try evictCleanCacheIfNeeded(reserving: bytes)
        let usage = try measuredCacheUsage()
        let (requiredBytes, overflow) = usage.totalBytes.addingReportingOverflow(bytes)
        guard !overflow, requiredBytes <= cacheLimitBytes else {
            throw TimeMachineSparseFileSessionError.cacheLimitExceeded(
                requiredBytes: overflow ? Int64.max : requiredBytes,
                limitBytes: cacheLimitBytes
            )
        }
    }

    private func evictCleanCacheIfNeeded(reserving bytes: Int64, fileManager: FileManager = .default) throws {
        let usage = try measuredCacheUsage(fileManager: fileManager)
        var total = usage.totalBytes
        let (initialRequired, initialOverflow) = total.addingReportingOverflow(bytes)
        guard initialOverflow || initialRequired > cacheLimitBytes else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: cleanCacheURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        var entries: [(url: URL, allocatedBytes: Int64, modificationTime: timespec)] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let attributes = try validatedCacheEntryAttributes(at: url)
            entries.append(
                (
                    url,
                    try allocatedBytes(from: attributes),
                    attributes.st_mtimespec
                )
            )
        }
        entries.sort {
            if $0.modificationTime.tv_sec == $1.modificationTime.tv_sec {
                return $0.modificationTime.tv_nsec < $1.modificationTime.tv_nsec
            }
            return $0.modificationTime.tv_sec < $1.modificationTime.tv_sec
        }
        for entry in entries {
            let (required, overflow) = total.addingReportingOverflow(bytes)
            guard overflow || required > cacheLimitBytes else { break }
            try fileManager.removeItem(at: entry.url)
            total = max(0, total - entry.allocatedBytes)
        }
    }

    private func cleanURL(forDigest digest: String) -> URL {
        cleanCacheURL.appendingPathComponent(digest, isDirectory: false)
    }

    private func dirtyURL(for key: ChunkKey) -> URL {
        let keyData = Data("\(key.path)\u{0}\(key.index)".utf8)
        let filename = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        return dirtyCacheURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func measuredCacheUsage(
        fileManager: FileManager = .default
    ) throws -> TimeMachineSparseFileCacheUsage {
        TimeMachineSparseFileCacheUsage(
            cleanBytes: try measuredAllocatedBytes(
                in: cleanCacheURL,
                fileManager: fileManager
            ),
            dirtyBytes: try measuredAllocatedBytes(
                in: dirtyCacheURL,
                fileManager: fileManager
            ),
            limitBytes: cacheLimitBytes
        )
    }

    private func measuredAllocatedBytes(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var total: Int64 = 0
        for url in urls {
            let allocated = try allocatedBytes(
                from: validatedCacheEntryAttributes(at: url)
            )
            let (next, overflow) = total.addingReportingOverflow(allocated)
            guard !overflow else { throw POSIXError(.EOVERFLOW) }
            total = next
        }
        return total
    }

    private func validatedCacheEntryAttributes(at url: URL) throws -> stat {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard
            (attributes.st_mode & S_IFMT) == S_IFREG,
            attributes.st_uid == geteuid(),
            attributes.st_nlink == 1,
            attributes.st_blocks >= 0
        else {
            throw POSIXError(.EPERM)
        }
        return attributes
    }

    private func allocatedBytes(from attributes: stat) throws -> Int64 {
        let (bytes, overflow) = Int64(attributes.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflow, bytes >= 0 else { throw POSIXError(.EOVERFLOW) }
        return bytes
    }

    private func validatedPath(_ path: String) throws -> String {
        guard TimeMachineRemotePathPolicy.isValid(path) else {
            throw TimeMachineSparseFileSessionError.invalidPath(path)
        }
        return path
    }

    private static func preparePrivateCacheDirectories(
        cacheURL: URL,
        cleanCacheURL: URL,
        dirtyCacheURL: URL,
        fileManager: FileManager
    ) throws {
        try securePrivateDirectory(
            at: cacheURL,
            createIntermediates: true,
            fileManager: fileManager
        )
        try securePrivateDirectory(
            at: cleanCacheURL,
            createIntermediates: false,
            fileManager: fileManager
        )

        var dirtyAttributes = stat()
        if Darwin.lstat(dirtyCacheURL.path, &dirtyAttributes) == 0 {
            // Dirty chunks are never authoritative after a service restart; a
            // committed authenticated generation is. Removing this entire leaf
            // also safely removes a substituted symlink rather than following it.
            try fileManager.removeItem(at: dirtyCacheURL)
        } else if errno != ENOENT {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        try securePrivateDirectory(
            at: dirtyCacheURL,
            createIntermediates: false,
            fileManager: fileManager
        )
    }

    private static func securePrivateDirectory(
        at url: URL,
        createIntermediates: Bool,
        fileManager: FileManager
    ) throws {
        var pathAttributes = stat()
        if Darwin.lstat(url.path, &pathAttributes) != 0 {
            guard errno == ENOENT else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var attributes = stat()
        guard
            Darwin.fstat(descriptor, &attributes) == 0,
            (attributes.st_mode & S_IFMT) == S_IFDIR,
            attributes.st_uid == geteuid()
        else {
            throw POSIXError(.EPERM)
        }
        guard Darwin.fchmod(descriptor, S_IRWXU) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
