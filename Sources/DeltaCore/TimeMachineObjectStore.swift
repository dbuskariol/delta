import CryptoKit
import Darwin
import Foundation

public enum TimeMachineObjectStoreError: Error, Equatable, LocalizedError {
    case localDestinationUnavailable
    case invalidObjectPath(String)
    case objectAlreadyExists(String)
    case objectNotFound(String)
    case invalidObjectDigest(expected: String, actual: String)
    case invalidManifest
    case invalidManifestAuthentication
    case invalidGeneration(expected: UInt64, actual: UInt64)
    case invalidParentManifest
    case manifestForkDetected(UInt64)
    case leaseHeld(ownerID: UUID, expiresAt: Date)
    case leaseLost
    case invalidAuthenticationKey
    case invalidGarbageCollectionMarker
    case garbageCollectionMetadataLimitExceeded(Int)
    case objectListingLimitExceeded(Int)
    case objectSizeLimitExceeded(Int)
    case invalidRemoteLease

    public var errorDescription: String? {
        switch self {
        case .localDestinationUnavailable:
            "The local or mounted Time Machine destination is unavailable. Reconnect the drive or server, restore access, then try again."
        case let .invalidObjectPath(path):
            "The Time Machine object path is invalid: \(path)."
        case let .objectAlreadyExists(path):
            "The Time Machine object already exists: \(path)."
        case let .objectNotFound(path):
            "The Time Machine object is missing: \(path)."
        case let .invalidObjectDigest(expected, actual):
            "A Time Machine object failed integrity verification (expected \(expected), found \(actual))."
        case .invalidManifest:
            "The remote Time Machine manifest is invalid."
        case .invalidManifestAuthentication:
            "The remote Time Machine manifest failed authentication."
        case let .invalidGeneration(expected, actual):
            "The remote Time Machine generation is out of sequence (expected \(expected), found \(actual))."
        case .invalidParentManifest:
            "The remote Time Machine generation does not continue from the committed parent."
        case let .manifestForkDetected(generation):
            "Two remote Time Machine histories claim generation \(generation). Delta stopped to prevent either history from being overwritten."
        case let .leaseHeld(ownerID, expiresAt):
            "Another Delta writer (\(ownerID.uuidString)) holds the remote Time Machine disk until \(expiresAt.formatted())."
        case .leaseLost:
            "Delta lost the remote Time Machine writer lease and stopped before publishing another generation."
        case .invalidAuthenticationKey:
            "The Time Machine manifest authentication key is missing or invalid."
        case .invalidGarbageCollectionMarker:
            "A remote Time Machine garbage-collection marker is invalid. Delta did not delete any associated backup data."
        case let .garbageCollectionMetadataLimitExceeded(limit):
            "The Time Machine history contains more than \(limit) unique metadata shards. Delta stopped cleanup before deleting data."
        case let .objectListingLimitExceeded(limit):
            "The Time Machine object listing exceeded Delta's \(limit)-entry safety limit. No storage mutation was performed."
        case let .objectSizeLimitExceeded(limit):
            "A Time Machine object exceeded Delta's \(limit)-byte safety limit. No generation was accepted."
        case .invalidRemoteLease:
            "The remote Time Machine writer lease is invalid. Delta stopped before changing the backup disk."
        }
    }
}

public enum TimeMachineLocalRootPolicy: Equatable, Sendable {
    /// First-time setup may create only the selected final directory. Every
    /// parent must already exist and the descriptor traversal remains
    /// no-follow and same-device.
    case createIfNeeded
    /// Existing disks must never reinterpret a missing provider as an empty
    /// remote history or recreate its selected directory on another volume.
    case requireExisting
}

enum TimeMachineBoundedRegularFile {
    static func byteCount(
        at url: URL,
        maximumBytes: Int = TimeMachineRepositorySettings.chunkSizeBytes
    ) throws -> Int {
        var attributes = stat()
        guard
            maximumBytes >= 0,
            Darwin.lstat(url.path, &attributes) == 0,
            (attributes.st_mode & S_IFMT) == S_IFREG,
            attributes.st_uid == Darwin.geteuid(),
            attributes.st_nlink == 1,
            attributes.st_size >= 0,
            attributes.st_size <= Int64(maximumBytes),
            let size = Int(exactly: attributes.st_size)
        else {
            if attributes.st_size > Int64(maximumBytes) {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(maximumBytes)
            }
            throw POSIXError(.EPERM)
        }
        return size
    }

    static func read(
        at url: URL,
        maximumBytes: Int = TimeMachineRepositorySettings.chunkSizeBytes,
        touchModificationDate: Bool = false
    ) throws -> Data {
        var result = Data()
        try read(
            at: url,
            maximumBytes: maximumBytes,
            touchModificationDate: touchModificationDate,
            into: &result
        )
        return result
    }

    static func read(
        at url: URL,
        maximumBytes: Int = TimeMachineRepositorySettings.chunkSizeBytes,
        touchModificationDate: Bool = false,
        into result: inout Data
    ) throws {
        guard maximumBytes >= 0 else {
            throw TimeMachineObjectStoreError.objectSizeLimitExceeded(maximumBytes)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
        }

        let initial = try attributes(of: descriptor)
        try validate(initial, maximumBytes: maximumBytes)
        let expectedCount = Int(initial.st_size)
        TimeMachineReusableDataBuffer.prepare(&result, count: expectedCount)
        var offset = 0
        while offset < expectedCount {
            let count = result.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    expectedCount - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw currentPOSIXError() }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += Int(count)
        }
        if touchModificationDate {
            // This descriptor is already identity-checked and no-follow. A
            // best-effort descriptor timestamp preserves clean-cache LRU
            // behavior without racing a path-based metadata mutation.
            _ = Darwin.futimens(descriptor, nil)
        }

        let final = try attributes(of: descriptor)
        var current = stat()
        guard
            Darwin.lstat(url.path, &current) == 0,
            final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino,
            final.st_uid == initial.st_uid,
            final.st_nlink == 1,
            final.st_size == initial.st_size,
            (final.st_mode & S_IFMT) == S_IFREG,
            current.st_dev == initial.st_dev,
            current.st_ino == initial.st_ino,
            current.st_uid == initial.st_uid,
            current.st_nlink == 1,
            current.st_size == initial.st_size,
            (current.st_mode & S_IFMT) == S_IFREG
        else {
            throw POSIXError(.EPERM)
        }
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw currentPOSIXError()
        }
        isOpen = false
    }

    private static func validate(_ attributes: stat, maximumBytes: Int) throws {
        guard
            (attributes.st_mode & S_IFMT) == S_IFREG,
            attributes.st_uid == Darwin.geteuid(),
            attributes.st_nlink == 1,
            attributes.st_size >= 0,
            attributes.st_size <= Int64(maximumBytes)
        else {
            if attributes.st_size > Int64(maximumBytes) {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(maximumBytes)
            }
            throw POSIXError(.EPERM)
        }
    }

    private static func attributes(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw currentPOSIXError()
        }
        return value
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }
}

enum TimeMachineReusableDataBuffer {
    static func prepare(_ data: inout Data, count: Int) {
        precondition(count >= 0)
        if data.count < count {
            data.append(Data(repeating: 0, count: count - data.count))
        } else if data.count > count {
            data.removeSubrange(count..<data.count)
        }
    }
}

public struct TimeMachineRemoteObjectMetadata: Equatable, Sendable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public enum TimeMachineObjectPayload: Sendable {
    case data(Data)
    case file(URL)

    public func loadData() throws -> Data {
        switch self {
        case let .data(data):
            return data
        case let .file(url):
            return try TimeMachineBoundedRegularFile.read(at: url)
        }
    }

    public func sha256Hex() throws -> String {
        switch self {
        case let .data(data):
            return TimeMachineGenerationStore.sha256Hex(data)
        case let .file(url):
            return TimeMachineGenerationStore.sha256Hex(
                try TimeMachineBoundedRegularFile.read(at: url)
            )
        }
    }

    public func byteCount() throws -> Int {
        switch self {
        case let .data(data):
            return data.count
        case let .file(url):
            return try TimeMachineBoundedRegularFile.byteCount(at: url)
        }
    }
}

public struct TimeMachineRemoteObjectWrite: Sendable {
    public var path: String
    public var payload: TimeMachineObjectPayload

    public init(path: String, payload: TimeMachineObjectPayload) {
        self.path = path
        self.payload = payload
    }
}

public protocol TimeMachineRemoteObjectTransport: Sendable {
    func readObject(at path: String) throws -> Data
    func readObject(at path: String, into buffer: inout Data) throws
    func readObjects(at paths: [String]) throws -> [String: Data]
    func writeObjectIfAbsent(_ data: Data, at path: String) throws
    func writeObjectsIfAbsent(_ objects: [TimeMachineRemoteObjectWrite]) throws
    func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata]
    func deleteObject(at path: String) throws
}

public extension TimeMachineRemoteObjectTransport {
    func readObject(at path: String, into buffer: inout Data) throws {
        buffer = try readObject(at: path)
    }

    func readObjects(at paths: [String]) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try readObject(at: path))
        })
    }

    func writeObjectsIfAbsent(_ objects: [TimeMachineRemoteObjectWrite]) throws {
        for object in objects {
            guard try object.payload.byteCount() <= TimeMachineRepositorySettings.chunkSizeBytes else {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                    TimeMachineRepositorySettings.chunkSizeBytes
                )
            }
            do {
                try writeObjectIfAbsent(try object.payload.loadData(), at: object.path)
            } catch TimeMachineObjectStoreError.objectAlreadyExists {
                // The read-back below makes retrying an immutable object safe.
            }
            let existing = try readObject(at: object.path)
            let expectedDigest = try object.payload.sha256Hex()
            let actualDigest = TimeMachineGenerationStore.sha256Hex(existing)
            guard expectedDigest == actualDigest else {
                throw TimeMachineObjectStoreError.invalidObjectDigest(
                    expected: expectedDigest,
                    actual: actualDigest
                )
            }
        }
    }
}

public struct AnyTimeMachineRemoteObjectTransport: TimeMachineRemoteObjectTransport, Sendable {
    private var read: @Sendable (String) throws -> Data
    private var readReusing: @Sendable (String, inout Data) throws -> Void
    private var readBatch: @Sendable ([String]) throws -> [String: Data]
    private var write: @Sendable (Data, String) throws -> Void
    private var writeBatch: @Sendable ([TimeMachineRemoteObjectWrite]) throws -> Void
    private var list: @Sendable (String) throws -> [TimeMachineRemoteObjectMetadata]
    private var delete: @Sendable (String) throws -> Void

    public init<Transport: TimeMachineRemoteObjectTransport>(_ transport: Transport) {
        read = transport.readObject
        readReusing = transport.readObject
        readBatch = transport.readObjects
        write = transport.writeObjectIfAbsent
        writeBatch = transport.writeObjectsIfAbsent
        list = transport.listObjects
        delete = transport.deleteObject
    }

    public init(
        read: @escaping @Sendable (String) throws -> Data,
        readReusing: (@Sendable (String, inout Data) throws -> Void)? = nil,
        readBatch: (@Sendable ([String]) throws -> [String: Data])? = nil,
        writeIfAbsent: @escaping @Sendable (Data, String) throws -> Void,
        writeBatchIfAbsent: (@Sendable ([TimeMachineRemoteObjectWrite]) throws -> Void)? = nil,
        list: @escaping @Sendable (String) throws -> [TimeMachineRemoteObjectMetadata],
        delete: @escaping @Sendable (String) throws -> Void
    ) {
        self.read = read
        self.readReusing = readReusing ?? { path, buffer in
            buffer = try read(path)
        }
        self.readBatch = readBatch ?? { paths in
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try read(path))
            })
        }
        self.write = writeIfAbsent
        self.writeBatch = writeBatchIfAbsent ?? { objects in
            for object in objects {
                guard try object.payload.byteCount() <= TimeMachineRepositorySettings.chunkSizeBytes else {
                    throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                        TimeMachineRepositorySettings.chunkSizeBytes
                    )
                }
                do {
                    try writeIfAbsent(try object.payload.loadData(), object.path)
                } catch TimeMachineObjectStoreError.objectAlreadyExists {
                    // Exact read-back verification below decides whether retry is safe.
                }
                let stored = try read(object.path)
                let expectedDigest = try object.payload.sha256Hex()
                let actualDigest = TimeMachineGenerationStore.sha256Hex(stored)
                guard expectedDigest == actualDigest else {
                    throw TimeMachineObjectStoreError.invalidObjectDigest(
                        expected: expectedDigest,
                        actual: actualDigest
                    )
                }
            }
        }
        self.list = list
        self.delete = delete
    }

    public func readObject(at path: String) throws -> Data {
        try read(path)
    }

    public func readObject(at path: String, into buffer: inout Data) throws {
        try readReusing(path, &buffer)
    }

    public func readObjects(at paths: [String]) throws -> [String: Data] {
        try readBatch(paths)
    }

    public func writeObjectIfAbsent(_ data: Data, at path: String) throws {
        try write(data, path)
    }

    public func writeObjectsIfAbsent(_ objects: [TimeMachineRemoteObjectWrite]) throws {
        try writeBatch(objects)
    }

    public func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata] {
        try list(prefix)
    }

    public func deleteObject(at path: String) throws {
        try delete(path)
    }
}

public struct LocalTimeMachineObjectTransport: TimeMachineRemoteObjectTransport, Sendable {
    private static let maximumListedObjects = 262_144

    public var rootURL: URL
    public var rootPolicy: TimeMachineLocalRootPolicy

    public init(
        rootURL: URL,
        rootPolicy: TimeMachineLocalRootPolicy = .createIfNeeded
    ) {
        // Resolve an intentionally selected symlink once, then pin every
        // operation to the resulting absolute path. Descriptor-relative
        // traversal below rejects later symlink substitutions at the root or
        // within the object namespace.
        self.rootURL = Self.canonicalRootURL(rootURL)
        self.rootPolicy = rootPolicy
    }

    public func readObject(at path: String) throws -> Data {
        var result = Data()
        try readObject(at: path, into: &result)
        return result
    }

    public func readObject(at path: String, into buffer: inout Data) throws {
        let components = try Self.validatedComponents(path, allowEmpty: false)
        do {
            let rootDescriptor = try openRootDirectory(createIfMissing: false)
            defer { _ = Darwin.close(rootDescriptor) }
            let rootAttributes = try Self.attributes(of: rootDescriptor)
            let parentDescriptor = try Self.openDirectoryChain(
                Array(components.dropLast()),
                rootDescriptor: rootDescriptor,
                rootDevice: rootAttributes.st_dev,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            try Self.readRegularFile(
                named: components[components.count - 1],
                parentDescriptor: parentDescriptor,
                rootDevice: rootAttributes.st_dev,
                into: &buffer
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            throw TimeMachineObjectStoreError.objectNotFound(path)
        }
    }

    public func writeObjectIfAbsent(_ data: Data, at path: String) throws {
        guard data.count <= TimeMachineRepositorySettings.chunkSizeBytes else {
            throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                TimeMachineRepositorySettings.chunkSizeBytes
            )
        }
        let components = try Self.validatedComponents(path, allowEmpty: false)
        let rootDescriptor = try openRootDirectory(createIfMissing: true)
        defer { _ = Darwin.close(rootDescriptor) }
        let rootAttributes = try Self.attributes(of: rootDescriptor)
        let parentDescriptor = try Self.openDirectoryChain(
            Array(components.dropLast()),
            rootDescriptor: rootDescriptor,
            rootDevice: rootAttributes.st_dev,
            createIfMissing: true
        )
        defer { _ = Darwin.close(parentDescriptor) }
        try Self.writeRegularFileIfAbsent(
            data,
            named: components[components.count - 1],
            path: path,
            parentDescriptor: parentDescriptor,
            rootDevice: rootAttributes.st_dev
        )
    }

    public func listObjects(withPrefix prefix: String) throws -> [TimeMachineRemoteObjectMetadata] {
        let validationPath = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let prefixComponents = try Self.validatedComponents(validationPath, allowEmpty: true)
        let traversalComponents: [String]
        if prefix.isEmpty || prefix.hasSuffix("/") {
            traversalComponents = prefixComponents
        } else {
            traversalComponents = Array(prefixComponents.dropLast())
        }
        let rootDescriptor: Int32
        do {
            rootDescriptor = try openRootDirectory(createIfMissing: false)
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        defer { _ = Darwin.close(rootDescriptor) }
        let rootAttributes = try Self.attributes(of: rootDescriptor)
        let traversalDescriptor: Int32
        do {
            traversalDescriptor = try Self.openDirectoryChain(
                traversalComponents,
                rootDescriptor: rootDescriptor,
                rootDevice: rootAttributes.st_dev,
                createIfMissing: false
            )
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
            return []
        }
        defer { _ = Darwin.close(traversalDescriptor) }
        var objects: [TimeMachineRemoteObjectMetadata] = []
        try Self.collectObjects(
            descriptor: traversalDescriptor,
            relativePrefix: traversalComponents.joined(separator: "/"),
            requestedPrefix: prefix,
            rootDevice: rootAttributes.st_dev,
            into: &objects
        )
        return objects.sorted { $0.path < $1.path }
    }

    public func deleteObject(at path: String) throws {
        let components = try Self.validatedComponents(path, allowEmpty: false)
        do {
            let rootDescriptor = try openRootDirectory(createIfMissing: false)
            defer { _ = Darwin.close(rootDescriptor) }
            let rootAttributes = try Self.attributes(of: rootDescriptor)
            let parentDescriptor = try Self.openDirectoryChain(
                Array(components.dropLast()),
                rootDescriptor: rootDescriptor,
                rootDevice: rootAttributes.st_dev,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            guard Darwin.unlinkat(parentDescriptor, components[components.count - 1], 0) == 0 else {
                throw Self.currentPOSIXError()
            }
            // Some local/network filesystems do not support directory fsync;
            // the immutable object protocol still verifies every publication.
            _ = Darwin.fsync(parentDescriptor)
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        }
    }

    private func openRootDirectory(createIfMissing: Bool) throws -> Int32 {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), !rootURL.path.contains("\0") else {
            throw TimeMachineObjectStoreError.invalidObjectPath(rootURL.path)
        }
        let components = rootURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else {
            throw Self.currentPOSIXError()
        }
        do {
            for (index, component) in components.enumerated() {
                var next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                if next < 0,
                   errno == ENOENT,
                   createIfMissing,
                   rootPolicy == .createIfNeeded,
                   index == components.indices.last {
                    if Darwin.mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
                        throw Self.currentPOSIXError()
                    }
                    next = Darwin.openat(
                        current,
                        component,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if next < 0,
                   rootPolicy == .requireExisting,
                   Self.isUnavailableRootError(errno) {
                    throw TimeMachineObjectStoreError.localDestinationUnavailable
                }
                guard next >= 0 else {
                    throw Self.currentPOSIXError()
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

    private static func canonicalRootURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let path = canonicalPath(standardized.path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Destination validation permits a missing final directory when its
        // parent is writable. Canonicalize that existing parent and append
        // only the leaf Delta may create.
        let parent = standardized.deletingLastPathComponent()
        if let parentPath = canonicalPath(parent.path) {
            return URL(fileURLWithPath: parentPath, isDirectory: true)
                .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
                .standardizedFileURL
        }
        return standardized
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
            return nil
        }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private static func isUnavailableRootError(_ value: Int32) -> Bool {
        value == ENOENT || value == ENOTDIR || value == EACCES
            || value == ENXIO || value == ESTALE
    }

    private static func validatedComponents(_ path: String, allowEmpty: Bool) throws -> [String] {
        if path.isEmpty, allowEmpty {
            return []
        }
        guard TimeMachineRemotePathPolicy.isValid(path) else {
            throw TimeMachineObjectStoreError.invalidObjectPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw TimeMachineObjectStoreError.invalidObjectPath(path)
        }
        return components
    }

    private static func openDirectoryChain(
        _ components: [String],
        rootDescriptor: Int32,
        rootDevice: dev_t,
        createIfMissing: Bool
    ) throws -> Int32 {
        var current = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else {
            throw currentPOSIXError()
        }
        do {
            for component in components {
                if createIfMissing,
                   Darwin.mkdirat(current, component, S_IRWXU) != 0,
                   errno != EEXIST {
                    throw currentPOSIXError()
                }
                let next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else {
                    throw currentPOSIXError()
                }
                let attributes = try self.attributes(of: next)
                guard
                    (attributes.st_mode & S_IFMT) == S_IFDIR,
                    attributes.st_dev == rootDevice
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

    private static func readRegularFile(
        named name: String,
        parentDescriptor: Int32,
        rootDevice: dev_t,
        into data: inout Data
    ) throws {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
        }
        let initial = try attributes(of: descriptor)
        guard
            (initial.st_mode & S_IFMT) == S_IFREG,
            initial.st_dev == rootDevice,
            initial.st_nlink == 1,
            initial.st_size >= 0,
            initial.st_size <= Int64(TimeMachineRepositorySettings.chunkSizeBytes)
        else {
            if initial.st_size > Int64(TimeMachineRepositorySettings.chunkSizeBytes) {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                    TimeMachineRepositorySettings.chunkSizeBytes
                )
            }
            throw POSIXError(.EPERM)
        }
        try readAll(
            from: descriptor,
            byteCount: Int(initial.st_size),
            into: &data
        )
        let final = try attributes(of: descriptor)
        var current = stat()
        guard
            Darwin.fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == initial.st_dev,
            current.st_ino == initial.st_ino,
            (current.st_mode & S_IFMT) == S_IFREG,
            current.st_size == initial.st_size,
            final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino,
            final.st_nlink == 1,
            final.st_size == initial.st_size
        else {
            throw POSIXError(.EPERM)
        }
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw currentPOSIXError()
        }
        isOpen = false
    }

    private static func writeRegularFileIfAbsent(
        _ data: Data,
        named name: String,
        path: String,
        parentDescriptor: Int32,
        rootDevice: dev_t
    ) throws {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw TimeMachineObjectStoreError.objectAlreadyExists(path)
            }
            throw currentPOSIXError()
        }
        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
        }
        let created = try attributes(of: descriptor)
        guard
            (created.st_mode & S_IFMT) == S_IFREG,
            created.st_dev == rootDevice,
            created.st_nlink == 1
        else {
            removeEntryIfIdentityMatches(parentDescriptor: parentDescriptor, name: name, expected: created)
            throw POSIXError(.EPERM)
        }

        var writeError: Error?
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    writeError = currentPOSIXError()
                    return
                }
                offset += count
            }
        }
        if writeError == nil, Darwin.fsync(descriptor) != 0 {
            writeError = currentPOSIXError()
        }
        if writeError == nil {
            do {
                let final = try attributes(of: descriptor)
                var current = stat()
                guard
                    final.st_dev == created.st_dev,
                    final.st_ino == created.st_ino,
                    final.st_nlink == 1,
                    Darwin.fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                    current.st_dev == created.st_dev,
                    current.st_ino == created.st_ino,
                    (current.st_mode & S_IFMT) == S_IFREG
                else {
                    throw POSIXError(.EPERM)
                }
            } catch {
                writeError = error
            }
        }
        if Darwin.close(descriptor) != 0, writeError == nil {
            writeError = currentPOSIXError()
        }
        isOpen = false
        if let writeError {
            removeEntryIfIdentityMatches(parentDescriptor: parentDescriptor, name: name, expected: created)
            throw writeError
        }
        // Best effort for filesystems that support durable directory entries.
        _ = Darwin.fsync(parentDescriptor)
    }

    private static func collectObjects(
        descriptor: Int32,
        relativePrefix: String,
        requestedPrefix: String,
        rootDevice: dev_t,
        into objects: inout [TimeMachineRemoteObjectMetadata]
    ) throws {
        for name in try directoryEntryNames(descriptor: descriptor) {
            let path = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            _ = try validatedComponents(path, allowEmpty: false)
            var entry = stat()
            guard Darwin.fstatat(descriptor, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw currentPOSIXError()
            }
            guard entry.st_dev == rootDevice else {
                throw POSIXError(.EPERM)
            }
            switch entry.st_mode & S_IFMT {
            case S_IFDIR:
                let child = Darwin.openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard child >= 0 else {
                    throw currentPOSIXError()
                }
                let current = try attributes(of: child)
                guard
                    current.st_dev == entry.st_dev,
                    current.st_ino == entry.st_ino,
                    (current.st_mode & S_IFMT) == S_IFDIR
                else {
                    _ = Darwin.close(child)
                    throw POSIXError(.EPERM)
                }
                defer { _ = Darwin.close(child) }
                try collectObjects(
                    descriptor: child,
                    relativePrefix: path,
                    requestedPrefix: requestedPrefix,
                    rootDevice: rootDevice,
                    into: &objects
                )
            case S_IFREG:
                guard entry.st_nlink == 1 else {
                    throw POSIXError(.EPERM)
                }
                guard path.hasPrefix(requestedPrefix) else { continue }
                guard objects.count < maximumListedObjects else {
                    throw TimeMachineObjectStoreError.objectListingLimitExceeded(
                        maximumListedObjects
                    )
                }
                objects.append(TimeMachineRemoteObjectMetadata(path: path, size: Int64(entry.st_size)))
            default:
                // App-owned object namespaces contain only directories and
                // immutable regular files. Never follow or silently accept a
                // substituted symlink, socket, device, or FIFO.
                throw POSIXError(.EPERM)
            }
        }
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw currentPOSIXError()
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
            let capacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw POSIXError(.EILSEQ)
            }
            if name != "." && name != ".." {
                guard names.count < maximumListedObjects else {
                    throw TimeMachineObjectStoreError.objectListingLimitExceeded(
                        maximumListedObjects
                    )
                }
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw currentPOSIXError()
        }
        return names
    }

    private static func readAll(
        from descriptor: Int32,
        byteCount: Int,
        into result: inout Data
    ) throws {
        TimeMachineReusableDataBuffer.prepare(&result, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = result.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw currentPOSIXError()
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += Int(count)
        }
    }

    private static func attributes(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw currentPOSIXError()
        }
        return value
    }

    private static func removeEntryIfIdentityMatches(
        parentDescriptor: Int32,
        name: String,
        expected: stat
    ) {
        var current = stat()
        guard
            Darwin.fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == expected.st_dev,
            current.st_ino == expected.st_ino,
            (current.st_mode & S_IFMT) == S_IFREG
        else {
            return
        }
        _ = Darwin.unlinkat(parentDescriptor, name, 0)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }
}

public struct TimeMachineChunkReference: Codable, Equatable, Hashable, Sendable {
    public var index: UInt64
    public var objectDigest: String
    public var byteCount: Int

    public init(index: UInt64, objectDigest: String, byteCount: Int) {
        self.index = index
        self.objectDigest = objectDigest
        self.byteCount = byteCount
    }
}

public struct TimeMachineRemoteFile: Codable, Equatable, Sendable {
    public var path: String
    public var logicalSize: UInt64
    public var chunks: [TimeMachineChunkReference]

    public init(path: String, logicalSize: UInt64, chunks: [TimeMachineChunkReference]) {
        self.path = path
        self.logicalSize = logicalSize
        self.chunks = chunks.sorted { $0.index < $1.index }
    }
}

public struct TimeMachineFileShardReference: Codable, Equatable, Hashable, Sendable {
    public var prefix: String
    public var objectDigest: String
    public var byteCount: Int
    public var fileCount: Int

    public init(prefix: String, objectDigest: String, byteCount: Int, fileCount: Int) {
        self.prefix = prefix
        self.objectDigest = objectDigest
        self.byteCount = byteCount
        self.fileCount = fileCount
    }
}

public struct TimeMachineFileShard: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var storeID: UUID
    public var prefix: String
    public var files: [TimeMachineRemoteFile]

    public init(storeID: UUID, prefix: String, files: [TimeMachineRemoteFile]) {
        self.formatVersion = Self.formatVersion
        self.storeID = storeID
        self.prefix = prefix
        self.files = files.sorted { $0.path < $1.path }
    }
}

public struct TimeMachineGenerationManifest: Codable, Equatable, Sendable {
    public static let formatVersion = 2

    public var formatVersion: Int
    public var storeID: UUID
    public var generation: UInt64
    public var parentManifestDigest: String?
    public var writerID: UUID
    public var createdAt: Date
    public var chunkSizeBytes: Int
    public var fileShards: [TimeMachineFileShardReference]

    public init(
        storeID: UUID,
        generation: UInt64,
        parentManifestDigest: String?,
        writerID: UUID,
        createdAt: Date = Date(),
        chunkSizeBytes: Int = TimeMachineRepositorySettings.chunkSizeBytes,
        fileShards: [TimeMachineFileShardReference]
    ) {
        self.formatVersion = Self.formatVersion
        self.storeID = storeID
        self.generation = generation
        self.parentManifestDigest = parentManifestDigest
        self.writerID = writerID
        self.createdAt = TimeMachineWireDate.canonical(createdAt)
        self.chunkSizeBytes = chunkSizeBytes
        self.fileShards = fileShards.sorted { $0.prefix < $1.prefix }
    }
}

public struct TimeMachineSignedManifest: Codable, Equatable, Sendable {
    public var manifest: TimeMachineGenerationManifest
    public var manifestDigest: String
    public var authenticationCode: String

    public init(manifest: TimeMachineGenerationManifest, manifestDigest: String, authenticationCode: String) {
        self.manifest = manifest
        self.manifestDigest = manifestDigest
        self.authenticationCode = authenticationCode
    }
}

public struct TimeMachineGenerationHead: Equatable, Sendable {
    public var signedManifest: TimeMachineSignedManifest
    public var objectPath: String

    public init(signedManifest: TimeMachineSignedManifest, objectPath: String) {
        self.signedManifest = signedManifest
        self.objectPath = objectPath
    }
}

public struct TimeMachineGarbageCollectionReport: Equatable, Sendable {
    public var inspectedBlobCount: Int
    public var newlyMarkedBlobCount: Int
    public var deletedBlobCount: Int
    public var clearedMarkerCount: Int

    public init(
        inspectedBlobCount: Int = 0,
        newlyMarkedBlobCount: Int = 0,
        deletedBlobCount: Int = 0,
        clearedMarkerCount: Int = 0
    ) {
        self.inspectedBlobCount = inspectedBlobCount
        self.newlyMarkedBlobCount = newlyMarkedBlobCount
        self.deletedBlobCount = deletedBlobCount
        self.clearedMarkerCount = clearedMarkerCount
    }
}

private struct TimeMachineGarbageCollectionCandidate: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var formatVersion: Int
    var storeID: UUID
    var objectDigest: String
    var firstSeenAt: Date
    var observedGeneration: UInt64
    var observedManifestDigest: String

    init(
        storeID: UUID,
        objectDigest: String,
        firstSeenAt: Date,
        observedGeneration: UInt64,
        observedManifestDigest: String
    ) {
        self.formatVersion = Self.formatVersion
        self.storeID = storeID
        self.objectDigest = objectDigest
        self.firstSeenAt = TimeMachineWireDate.canonical(firstSeenAt)
        self.observedGeneration = observedGeneration
        self.observedManifestDigest = observedManifestDigest
    }
}

private struct TimeMachineSignedGarbageCollectionCandidate: Codable, Equatable, Sendable {
    var candidate: TimeMachineGarbageCollectionCandidate
    var candidateDigest: String
    var authenticationCode: String
}

public struct TimeMachineRemoteLease: Codable, Equatable, Sendable {
    public var storeID: UUID
    public var ownerID: UUID
    public var nonce: UUID
    public var issuedAt: Date
    public var expiresAt: Date
    public var observedGeneration: UInt64

    public init(
        storeID: UUID,
        ownerID: UUID,
        nonce: UUID = UUID(),
        issuedAt: Date,
        expiresAt: Date,
        observedGeneration: UInt64
    ) {
        self.storeID = storeID
        self.ownerID = ownerID
        self.nonce = nonce
        self.issuedAt = TimeMachineWireDate.canonical(issuedAt)
        self.expiresAt = TimeMachineWireDate.canonical(expiresAt)
        self.observedGeneration = observedGeneration
    }
}

public struct TimeMachineGenerationCommit: Sendable {
    public var manifest: TimeMachineGenerationManifest
    public var objectsByDigest: [String: TimeMachineObjectPayload]

    public init(manifest: TimeMachineGenerationManifest, objectsByDigest: [String: TimeMachineObjectPayload]) {
        self.manifest = manifest
        self.objectsByDigest = objectsByDigest
    }

    public init(manifest: TimeMachineGenerationManifest, objectsByDigest: [String: Data]) {
        self.init(
            manifest: manifest,
            objectsByDigest: objectsByDigest.mapValues(TimeMachineObjectPayload.data)
        )
    }
}

public struct TimeMachineGenerationStore: Sendable {
    private static let maximumManifestObjectBytes: Int64 = 4 * 1_048_576
    // Normal operation retains 256 generations, but a provider-side delete
    // outage must not make the current head unreadable after only a few large
    // backups. Listing remains bounded while leaving ample recovery room for
    // later authenticated compaction.
    private static let maximumManifestCandidates = 65_536
    static let maximumRemoteFileCount = Int(
        TimeMachineRepositorySettings.maximumImageCapacityBytes
            / Int64(TimeMachineRepositorySettings.chunkSizeBytes)
    ) + 1_024
    static let maximumChunkReferenceCount = Int(
        (TimeMachineRepositorySettings.maximumImageCapacityBytes
            + 1_073_741_824)
            / Int64(TimeMachineRepositorySettings.chunkSizeBytes)
    ) + 1
    private static let maximumLeaseCandidates = 1_024
    private static let maximumLeaseObjectBytes: Int64 = 64 * 1_024
    // Runtime writers use five minutes, while an explicitly bounded offline
    // maintenance pass may span hours on a large remote store.
    private static let maximumLeaseDuration: TimeInterval = 24 * 60 * 60
    private static let maximumObjectsPerDigestPrefix = 262_144

    private let namespace: String
    private let storeID: UUID
    private let authenticationKey: SymmetricKey
    private let transport: AnyTimeMachineRemoteObjectTransport

    public init<Transport: TimeMachineRemoteObjectTransport>(
        namespace: String,
        storeID: UUID,
        authenticationKey: Data,
        transport: Transport
    ) throws {
        guard authenticationKey.count >= 32 else {
            throw TimeMachineObjectStoreError.invalidAuthenticationKey
        }
        let normalizedNamespace = namespace.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard TimeMachineRemotePathPolicy.isValid(normalizedNamespace) else {
            throw TimeMachineObjectStoreError.invalidObjectPath(namespace)
        }
        self.namespace = normalizedNamespace
        self.storeID = storeID
        self.authenticationKey = SymmetricKey(data: authenticationKey)
        self.transport = AnyTimeMachineRemoteObjectTransport(transport)
    }

    public func loadHead() throws -> TimeMachineGenerationHead? {
        let prefix = "\(namespace)/manifests/"
        let candidates = try transport.listObjects(withPrefix: prefix)
            .filter { $0.path.hasSuffix(".json") }
        guard candidates.count <= Self.maximumManifestCandidates else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let generationCandidates = candidates.compactMap { candidate -> (UInt64, TimeMachineRemoteObjectMetadata)? in
            let filename = URL(fileURLWithPath: candidate.path).lastPathComponent
            guard
                filename.count > 20,
                filename[filename.index(filename.startIndex, offsetBy: 20)] == "-",
                let generation = UInt64(filename.prefix(20))
            else {
                return nil
            }
            return (generation, candidate)
        }
        guard let highestGeneration = generationCandidates.map(\.0).max() else {
            return nil
        }
        var validHeads: [TimeMachineGenerationHead] = []
        for (_, candidate) in generationCandidates where candidate.path.contains(
            "/\(String(format: "%020llu", highestGeneration))-"
        ) {
            guard
                candidate.size > 0,
                candidate.size <= Self.maximumManifestObjectBytes
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            guard
                let data = try? transport.readObject(at: candidate.path),
                let signedManifest = try? decodeAndVerifySignedManifest(data),
                signedManifest.manifest.storeID == storeID,
                signedManifest.manifest.formatVersion == TimeMachineGenerationManifest.formatVersion,
                signedManifest.manifest.generation == highestGeneration,
                candidate.path == manifestPath(
                    generation: highestGeneration,
                    digest: signedManifest.manifestDigest,
                    writerID: signedManifest.manifest.writerID
                )
            else {
                continue
            }
            validHeads.append(TimeMachineGenerationHead(signedManifest: signedManifest, objectPath: candidate.path))
        }
        guard !validHeads.isEmpty else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let uniqueDigests = Set(validHeads.map(\.signedManifest.manifestDigest))
        guard uniqueDigests.count == 1, let head = validHeads.first else {
            throw TimeMachineObjectStoreError.manifestForkDetected(highestGeneration)
        }
        return head
    }

    public static func makeFileShards(
        storeID: UUID,
        files: [TimeMachineRemoteFile],
        excludingObjectDigests: Set<String> = []
    ) throws -> (references: [TimeMachineFileShardReference], objectsByDigest: [String: Data]) {
        try validateFileStructure(files)
        let groups = Dictionary(grouping: files) { fileShardPrefix(for: $0.path) }
        var references: [TimeMachineFileShardReference] = []
        var objects: [String: Data] = [:]
        for prefix in groups.keys.sorted() {
            guard let shardFiles = groups[prefix] else { continue }
            let shard = TimeMachineFileShard(storeID: storeID, prefix: prefix, files: shardFiles)
            let data = try canonicalEncoder.encode(shard)
            guard Int64(data.count) <= maximumManifestObjectBytes else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            let digest = sha256Hex(data)
            references.append(
                TimeMachineFileShardReference(
                    prefix: prefix,
                    objectDigest: digest,
                    byteCount: data.count,
                    fileCount: shardFiles.count
                )
            )
            if !excludingObjectDigests.contains(digest) {
                objects[digest] = data
            }
        }
        guard references.count <= 4_096 else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        return (references, objects)
    }

    public func loadFiles(from head: TimeMachineGenerationHead) throws -> [TimeMachineRemoteFile] {
        try loadFiles(
            from: head.signedManifest.manifest,
            suppliedObjects: [:]
        )
    }

    /// Durably writes content-addressed payloads without publishing a new
    /// generation. A mounted disk uses this when its fixed local working
    /// window fills: the bytes become reconstructible from the provider, but
    /// remain unreachable from authenticated history until a later FSKit
    /// synchronization barrier publishes the signed manifest.
    ///
    /// A crash before that barrier leaves only harmless unreferenced objects,
    /// which normal delayed garbage collection can reclaim. Lease checks on
    /// both sides of the upload prevent a superseded writer from using staged
    /// payloads to advance history.
    public func stageObjects(
        _ objectsByDigest: [String: TimeMachineObjectPayload],
        lease: TimeMachineRemoteLease,
        now: Date? = nil
    ) throws {
        guard objectsByDigest.count <= Self.maximumChunkReferenceCount else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        var stagedBytes: Int64 = 0
        for payload in objectsByDigest.values {
            let byteCount = try payload.byteCount()
            guard byteCount <= TimeMachineRepositorySettings.chunkSizeBytes else {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                    TimeMachineRepositorySettings.chunkSizeBytes
                )
            }
            let (nextBytes, overflowed) = stagedBytes.addingReportingOverflow(
                Int64(byteCount)
            )
            guard
                !overflowed,
                nextBytes <= TimeMachineRepositorySettings.remoteSpillBatchBytes
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            stagedBytes = nextBytes
        }
        try verifyLease(lease, now: now ?? Date())
        try writeVerifiedObjects(objectsByDigest)
        try verifyLeaseOwner(lease.ownerID, now: now ?? Date())
    }

    public func commit(
        _ commit: TimeMachineGenerationCommit,
        lease: TimeMachineRemoteLease? = nil,
        now: Date? = nil
    ) throws -> TimeMachineGenerationHead {
        let previousHead = try loadHead()
        let (expectedGeneration, generationOverflowed) =
            (previousHead?.signedManifest.manifest.generation ?? 0).addingReportingOverflow(1)
        guard !generationOverflowed else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard commit.manifest.generation == expectedGeneration else {
            throw TimeMachineObjectStoreError.invalidGeneration(
                expected: expectedGeneration,
                actual: commit.manifest.generation
            )
        }
        guard commit.manifest.storeID == storeID else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard commit.manifest.parentManifestDigest == previousHead?.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.invalidParentManifest
        }
        try validateManifest(
            commit.manifest,
            previousManifest: previousHead?.signedManifest.manifest,
            suppliedObjects: commit.objectsByDigest
        )
        if let lease {
            try verifyLease(lease, now: now ?? Date())
            guard lease.ownerID == commit.manifest.writerID else {
                throw TimeMachineObjectStoreError.leaseLost
            }
        }

        try writeVerifiedObjects(commit.objectsByDigest)
        if let lease {
            try verifyLeaseOwner(lease.ownerID, now: now ?? Date())
        }

        let signedManifest = try makeSignedManifest(commit.manifest)
        let manifestData = try Self.canonicalEncoder.encode(signedManifest)
        let manifestPath = self.manifestPath(
            generation: commit.manifest.generation,
            digest: signedManifest.manifestDigest,
            writerID: commit.manifest.writerID
        )
        do {
            try transport.writeObjectIfAbsent(manifestData, at: manifestPath)
        } catch TimeMachineObjectStoreError.objectAlreadyExists {
            let existing = try transport.readObject(at: manifestPath)
            guard existing == manifestData else {
                throw TimeMachineObjectStoreError.manifestForkDetected(commit.manifest.generation)
            }
        }
        let readBack = try transport.readObject(at: manifestPath)
        let verifiedManifest = try decodeAndVerifySignedManifest(readBack)
        guard verifiedManifest == signedManifest else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        if let lease {
            try verifyLeaseOwner(lease.ownerID, now: now ?? Date())
        }
        let head = try loadHead()
        guard head?.signedManifest.manifestDigest == signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.manifestForkDetected(commit.manifest.generation)
        }
        return TimeMachineGenerationHead(signedManifest: signedManifest, objectPath: manifestPath)
    }

    private func writeVerifiedObjects(
        _ objectsByDigest: [String: TimeMachineObjectPayload]
    ) throws {
        var objectWrites: [TimeMachineRemoteObjectWrite] = []
        var batchBytes: Int64 = 0
        objectWrites.reserveCapacity(min(objectsByDigest.count, 64))

        func flushBatch() throws {
            guard !objectWrites.isEmpty else { return }
            try transport.writeObjectsIfAbsent(objectWrites)
            objectWrites.removeAll(keepingCapacity: true)
            batchBytes = 0
        }

        for digest in objectsByDigest.keys.sorted() {
            guard let payload = objectsByDigest[digest] else { continue }
            let actualDigest = try payload.sha256Hex()
            guard actualDigest == digest else {
                throw TimeMachineObjectStoreError.invalidObjectDigest(
                    expected: digest,
                    actual: actualDigest
                )
            }
            let byteCount = try payload.byteCount()
            guard byteCount <= TimeMachineRepositorySettings.chunkSizeBytes else {
                throw TimeMachineObjectStoreError.objectSizeLimitExceeded(
                    TimeMachineRepositorySettings.chunkSizeBytes
                )
            }
            let (nextBatchBytes, overflowed) = batchBytes.addingReportingOverflow(
                Int64(byteCount)
            )
            if !objectWrites.isEmpty,
               (overflowed || nextBatchBytes > TimeMachineRepositorySettings.remoteSpillBatchBytes)
            {
                try flushBatch()
            }
            objectWrites.append(
                TimeMachineRemoteObjectWrite(
                    path: objectPath(forDigest: digest),
                    payload: payload
                )
            )
            batchBytes += Int64(byteCount)
        }
        try flushBatch()
    }

    public func readChunk(_ reference: TimeMachineChunkReference) throws -> Data {
        var data = Data()
        try readChunk(reference, into: &data)
        return data
    }

    public func readChunk(
        _ reference: TimeMachineChunkReference,
        into data: inout Data
    ) throws {
        try transport.readObject(
            at: objectPath(forDigest: reference.objectDigest),
            into: &data
        )
        let digest = Self.sha256Hex(data)
        guard digest == reference.objectDigest else {
            throw TimeMachineObjectStoreError.invalidObjectDigest(expected: reference.objectDigest, actual: digest)
        }
        guard data.count == reference.byteCount else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
    }

    public func acquireLease(
        ownerID: UUID,
        duration: TimeInterval = 120,
        now: Date = Date()
    ) throws -> TimeMachineRemoteLease {
        guard
            duration.isFinite,
            duration > 0,
            duration <= Self.maximumLeaseDuration
        else {
            throw TimeMachineObjectStoreError.invalidRemoteLease
        }
        if let active = try activeLease(now: now) {
            guard active.ownerID == ownerID else {
                throw TimeMachineObjectStoreError.leaseHeld(ownerID: active.ownerID, expiresAt: active.expiresAt)
            }
            // A local process lock proves the previous process is gone. Reusing
            // its persisted owner ID lets a launchd restart renew the orphaned
            // lease immediately instead of leaving the mounted disk offline.
            return try renewLease(active, duration: duration, now: now)
        }
        let generation = try loadHead()?.signedManifest.manifest.generation ?? 0
        let lease = TimeMachineRemoteLease(
            storeID: storeID,
            ownerID: ownerID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(duration),
            observedGeneration: generation
        )
        let path = leasePath(lease)
        try transport.writeObjectIfAbsent(try Self.canonicalEncoder.encode(lease), at: path)
        guard try activeLease(now: now) == lease else {
            try? transport.deleteObject(at: path)
            throw TimeMachineObjectStoreError.leaseLost
        }
        return lease
    }

    public func verifyLease(_ lease: TimeMachineRemoteLease, now: Date = Date()) throws {
        guard lease.storeID == storeID, lease.expiresAt > now else {
            throw TimeMachineObjectStoreError.leaseLost
        }
        guard try activeLease(now: now) == lease else {
            throw TimeMachineObjectStoreError.leaseLost
        }
    }

    public func verifyLeaseOwner(_ ownerID: UUID, now: Date = Date()) throws {
        guard
            let active = try activeLease(now: now),
            active.ownerID == ownerID,
            active.expiresAt > now
        else {
            throw TimeMachineObjectStoreError.leaseLost
        }
    }

    public func renewLease(
        _ lease: TimeMachineRemoteLease,
        duration: TimeInterval = 120,
        now: Date = Date()
    ) throws -> TimeMachineRemoteLease {
        guard
            duration.isFinite,
            duration > 0,
            duration <= Self.maximumLeaseDuration
        else {
            throw TimeMachineObjectStoreError.invalidRemoteLease
        }
        try verifyLease(lease, now: now)
        let renewed = TimeMachineRemoteLease(
            storeID: storeID,
            ownerID: lease.ownerID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(duration),
            observedGeneration: try loadHead()?.signedManifest.manifest.generation ?? 0
        )
        let renewedPath = leasePath(renewed)
        try transport.writeObjectIfAbsent(
            try Self.canonicalEncoder.encode(renewed),
            at: renewedPath
        )
        try transport.deleteObject(at: leasePath(lease))
        guard try activeLease(now: now) == renewed else {
            try? transport.deleteObject(at: renewedPath)
            throw TimeMachineObjectStoreError.leaseLost
        }
        return renewed
    }

    public func releaseLease(_ lease: TimeMachineRemoteLease) throws {
        try transport.deleteObject(at: leasePath(lease))
    }

    public func pruneManifestHistory(
        keepingNewestGenerations keepCount: Int,
        expectedHead: TimeMachineGenerationHead,
        lease: TimeMachineRemoteLease,
        now: Date = Date()
    ) throws {
        guard keepCount > 0 else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        try verifyLeaseOwner(lease.ownerID, now: now)
        let heads = try loadValidatedManifestHistory()
        guard !heads.isEmpty else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard heads.last?.signedManifest.manifestDigest
            == expectedHead.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.leaseLost
        }
        let generationsToKeep = Set(heads.map(\.signedManifest.manifest.generation).suffix(keepCount))
        var deleteCount = 0
        for head in heads where !generationsToKeep.contains(head.signedManifest.manifest.generation) {
            if deleteCount.isMultiple(of: 32) {
                try verifyLeaseOwner(lease.ownerID, now: now)
                guard try loadHead()?.signedManifest.manifestDigest
                    == expectedHead.signedManifest.manifestDigest else {
                    throw TimeMachineObjectStoreError.leaseLost
                }
            }
            try transport.deleteObject(at: head.objectPath)
            deleteCount += 1
        }
        try verifyLeaseOwner(lease.ownerID, now: now)
        guard try loadHead()?.signedManifest.manifestDigest
            == expectedHead.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.leaseLost
        }
    }

    public func garbageCollectUnreferencedBlobs(
        lease: inout TimeMachineRemoteLease,
        expectedHead: TimeMachineGenerationHead,
        gracePeriod: TimeInterval = 24 * 60 * 60,
        now fixedNow: Date? = nil
    ) throws -> TimeMachineGarbageCollectionReport {
        guard gracePeriod >= 0 else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        func currentTime() -> Date { fixedNow ?? Date() }

        try maintainLease(&lease, now: currentTime())
        guard let initialHead = try loadHead() else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard initialHead.signedManifest.manifestDigest
            == expectedHead.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.leaseLost
        }
        let history = try loadValidatedManifestHistory()
        guard !history.isEmpty else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard history.last?.signedManifest.manifestDigest
            == initialHead.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let referenced = try referencedBlobMembership(in: history.map(\.signedManifest.manifest))
        var report = TimeMachineGarbageCollectionReport()

        for prefixValue in 0..<256 {
            let operationTime = currentTime()
            try maintainLease(&lease, now: operationTime)
            if prefixValue.isMultiple(of: 16) {
                guard try loadHead()?.signedManifest.manifestDigest
                    == initialHead.signedManifest.manifestDigest else {
                    throw TimeMachineObjectStoreError.leaseLost
                }
            }

            let digestPrefix = String(format: "%02x", prefixValue)
            let blobPrefix = "\(namespace)/blobs/sha256/\(digestPrefix)/"
            let markerPrefix = "\(namespace)/gc/candidates/\(digestPrefix)/"
            let blobs = try transport.listObjects(withPrefix: blobPrefix)
            let markers = try transport.listObjects(withPrefix: markerPrefix)
            guard
                blobs.count <= Self.maximumObjectsPerDigestPrefix,
                markers.count <= Self.maximumObjectsPerDigestPrefix
            else {
                throw TimeMachineObjectStoreError.objectListingLimitExceeded(
                    Self.maximumObjectsPerDigestPrefix
                )
            }
            var blobPathsByDigest: [String: String] = [:]
            var markerPathsByDigest: [String: String] = [:]

            for blob in blobs {
                guard let digest = digestFromBlobPath(blob.path, prefix: blobPrefix) else {
                    continue
                }
                blobPathsByDigest[digest] = blob.path
            }
            for marker in markers {
                guard let digest = digestFromMarkerPath(marker.path, prefix: markerPrefix) else {
                    continue
                }
                markerPathsByDigest[digest] = marker.path
            }

            for digest in blobPathsByDigest.keys.sorted() {
                guard let blobPath = blobPathsByDigest[digest] else { continue }
                report.inspectedBlobCount += 1
                if referenced.contains(digest) {
                    if let markerPath = markerPathsByDigest.removeValue(forKey: digest) {
                        try transport.deleteObject(at: markerPath)
                        report.clearedMarkerCount += 1
                    }
                    continue
                }

                if let markerPath = markerPathsByDigest.removeValue(forKey: digest) {
                    let marker = try loadGarbageCollectionCandidate(
                        at: markerPath,
                        expectedObjectDigest: digest
                    )
                    guard operationTime.timeIntervalSince(marker.firstSeenAt) >= gracePeriod else {
                        continue
                    }
                    try maintainLease(&lease, now: currentTime())
                    try transport.deleteObject(at: blobPath)
                    try transport.deleteObject(at: markerPath)
                    report.deletedBlobCount += 1
                    report.clearedMarkerCount += 1
                    continue
                }

                let candidate = TimeMachineGarbageCollectionCandidate(
                    storeID: storeID,
                    objectDigest: digest,
                    firstSeenAt: operationTime,
                    observedGeneration: initialHead.signedManifest.manifest.generation,
                    observedManifestDigest: initialHead.signedManifest.manifestDigest
                )
                let markerPath = garbageCollectionMarkerPath(forDigest: digest)
                let markerData = try encodeGarbageCollectionCandidate(candidate)
                do {
                    try transport.writeObjectIfAbsent(markerData, at: markerPath)
                    report.newlyMarkedBlobCount += 1
                } catch TimeMachineObjectStoreError.objectAlreadyExists {
                    // A concurrent retry may have created the same immutable marker.
                }
                _ = try loadGarbageCollectionCandidate(
                    at: markerPath,
                    expectedObjectDigest: digest
                )
            }

            // Candidate records are metadata only. Removing a marker whose blob
            // no longer exists cannot make any generation unreachable.
            for markerPath in markerPathsByDigest.values {
                try transport.deleteObject(at: markerPath)
                report.clearedMarkerCount += 1
            }
        }

        try maintainLease(&lease, now: currentTime())
        guard try loadHead()?.signedManifest.manifestDigest
            == initialHead.signedManifest.manifestDigest else {
            throw TimeMachineObjectStoreError.leaseLost
        }
        withExtendedLifetime(referenced) {}
        return report
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        sha256Hex(try TimeMachineBoundedRegularFile.read(at: url))
    }

    private func activeLease(now: Date) throws -> TimeMachineRemoteLease? {
        let prefix = "\(namespace)/leases/"
        let candidates = try transport.listObjects(withPrefix: prefix)
        guard candidates.count <= Self.maximumLeaseCandidates else {
            throw TimeMachineObjectStoreError.objectListingLimitExceeded(
                Self.maximumLeaseCandidates
            )
        }
        var active: [(lease: TimeMachineRemoteLease, path: String)] = []
        for candidate in candidates {
            guard candidate.size > 0, candidate.size <= Self.maximumLeaseObjectBytes else {
                throw TimeMachineObjectStoreError.invalidRemoteLease
            }
            let data: Data
            do {
                data = try transport.readObject(at: candidate.path)
            } catch TimeMachineObjectStoreError.objectNotFound {
                // Object-store listings may briefly retain a just-deleted
                // immutable lease. Its absence cannot represent an active lock.
                continue
            }
            guard let lease = try? Self.canonicalDecoder.decode(
                TimeMachineRemoteLease.self,
                from: data
            ) else {
                throw TimeMachineObjectStoreError.invalidRemoteLease
            }
            let duration = lease.expiresAt.timeIntervalSince(lease.issuedAt)
            guard
                lease.storeID == storeID,
                candidate.path == leasePath(lease),
                duration.isFinite,
                duration > 0,
                duration <= Self.maximumLeaseDuration
            else {
                // A copied or unrelated JSON object is not a lease merely
                // because it resides beneath the lease prefix.
                continue
            }
            if lease.expiresAt <= now {
                try? transport.deleteObject(at: candidate.path)
                continue
            }
            active.append((lease, candidate.path))
        }
        return active.sorted { lhs, rhs in
            if lhs.lease.issuedAt != rhs.lease.issuedAt {
                return lhs.lease.issuedAt < rhs.lease.issuedAt
            }
            return lhs.path < rhs.path
        }.first?.lease
    }

    private func maintainLease(
        _ lease: inout TimeMachineRemoteLease,
        now: Date
    ) throws {
        if lease.expiresAt.timeIntervalSince(now) <= 120 {
            lease = try renewLease(lease, duration: 300, now: now)
        } else {
            try verifyLeaseOwner(lease.ownerID, now: now)
        }
    }

    /// Loads every retained manifest through bounded transport batches,
    /// authenticates its canonical path and contents, rejects forks, and
    /// verifies that the retained suffix is an unbroken parent chain. The
    /// first retained generation may be greater than one after authenticated
    /// history pruning; every generation after it must be consecutive.
    ///
    /// This intentionally remains an offline/startup operation. Runtime sparse
    /// file writes use the already authenticated head and do not enumerate the
    /// remote history for every filesystem request.
    public func loadValidatedManifestHistory() throws -> [TimeMachineGenerationHead] {
        let prefix = "\(namespace)/manifests/"
        let candidates = try transport.listObjects(withPrefix: prefix)
            .filter { $0.path.hasSuffix(".json") }
        guard candidates.count <= Self.maximumManifestCandidates else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        var parsedCandidates: [(generation: UInt64, metadata: TimeMachineRemoteObjectMetadata)] = []
        for candidate in candidates {
            let filename = URL(fileURLWithPath: candidate.path).lastPathComponent
            guard
                filename.count > 20,
                filename[filename.index(filename.startIndex, offsetBy: 20)] == "-",
                let generation = UInt64(filename.prefix(20))
            else {
                continue
            }
            guard candidate.size > 0, candidate.size <= Self.maximumManifestObjectBytes else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            parsedCandidates.append((generation, candidate))
        }
        var headsByGeneration: [UInt64: [TimeMachineGenerationHead]] = [:]
        var batch: [(generation: UInt64, metadata: TimeMachineRemoteObjectMetadata)] = []
        var batchBytes: Int64 = 0
        for candidate in parsedCandidates {
            if !batch.isEmpty, batchBytes + candidate.metadata.size > 64 * 1_048_576 {
                try decodeManifestHistoryBatch(
                    batch,
                    into: &headsByGeneration
                )
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
            batch.append(candidate)
            batchBytes += candidate.metadata.size
        }
        if !batch.isEmpty {
            try decodeManifestHistoryBatch(batch, into: &headsByGeneration)
        }

        var history: [TimeMachineGenerationHead] = []
        for generation in headsByGeneration.keys.sorted() {
            guard let candidates = headsByGeneration[generation] else { continue }
            let digests = Set(candidates.map(\.signedManifest.manifestDigest))
            guard digests.count == 1, let head = candidates.first else {
                throw TimeMachineObjectStoreError.manifestForkDetected(generation)
            }
            if let previous = history.last {
                let (expectedGeneration, generationOverflowed) = previous.signedManifest
                    .manifest.generation.addingReportingOverflow(1)
                guard !generationOverflowed else {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                guard generation == expectedGeneration else {
                    throw TimeMachineObjectStoreError.invalidGeneration(
                        expected: expectedGeneration,
                        actual: generation
                    )
                }
                guard head.signedManifest.manifest.parentManifestDigest
                    == previous.signedManifest.manifestDigest else {
                    throw TimeMachineObjectStoreError.invalidParentManifest
                }
            } else if generation == 1 {
                guard head.signedManifest.manifest.parentManifestDigest == nil else {
                    throw TimeMachineObjectStoreError.invalidParentManifest
                }
            } else {
                guard head.signedManifest.manifest.parentManifestDigest != nil else {
                    throw TimeMachineObjectStoreError.invalidParentManifest
                }
            }
            history.append(head)
        }
        return history
    }

    private func decodeManifestHistoryBatch(
        _ batch: [(generation: UInt64, metadata: TimeMachineRemoteObjectMetadata)],
        into headsByGeneration: inout [UInt64: [TimeMachineGenerationHead]]
    ) throws {
        let objects = try transport.readObjects(at: batch.map(\.metadata.path))
        for (generation, candidate) in batch {
            guard let data = objects[candidate.path] else {
                throw TimeMachineObjectStoreError.objectNotFound(candidate.path)
            }
            let signed = try decodeAndVerifySignedManifest(data)
            guard
                signed.manifest.storeID == storeID,
                signed.manifest.formatVersion == TimeMachineGenerationManifest.formatVersion,
                signed.manifest.generation == generation,
                candidate.path == manifestPath(
                    generation: generation,
                    digest: signed.manifestDigest,
                    writerID: signed.manifest.writerID
                )
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            try validateShardReferences(in: signed.manifest)
            headsByGeneration[generation, default: []].append(
                TimeMachineGenerationHead(
                    signedManifest: signed,
                    objectPath: candidate.path
                )
            )
        }
    }

    private func referencedBlobMembership(
        in manifests: [TimeMachineGenerationManifest]
    ) throws -> TimeMachineDigestMembership {
        let uniqueShardLimit = 262_144
        var shardReferences: [String: TimeMachineFileShardReference] = [:]
        var membership = TimeMachineDigestMembership()
        for manifest in manifests {
            try validateShardReferences(in: manifest)
            for reference in manifest.fileShards {
                membership.insert(reference.objectDigest)
                if let existing = shardReferences[reference.objectDigest], existing != reference {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                shardReferences[reference.objectDigest] = reference
                guard shardReferences.count <= uniqueShardLimit else {
                    throw TimeMachineObjectStoreError.garbageCollectionMetadataLimitExceeded(
                        uniqueShardLimit
                    )
                }
            }
        }

        let references = shardReferences.values.sorted { $0.objectDigest < $1.objectDigest }
        var batch: [TimeMachineFileShardReference] = []
        var batchBytes = 0
        func process(_ batch: [TimeMachineFileShardReference], membership: inout TimeMachineDigestMembership) throws {
            let paths = batch.map { objectPath(forDigest: $0.objectDigest) }
            let objects = try transport.readObjects(at: paths)
            for reference in batch {
                let path = objectPath(forDigest: reference.objectDigest)
                guard let data = objects[path] else {
                    throw TimeMachineObjectStoreError.objectNotFound(path)
                }
                for file in try decodeFileShard(reference, data: data) {
                    for chunk in file.chunks {
                        membership.insert(chunk.objectDigest)
                    }
                }
            }
        }
        for reference in references {
            if !batch.isEmpty, batchBytes + reference.byteCount > 64 * 1_048_576 {
                try process(batch, membership: &membership)
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
            batch.append(reference)
            batchBytes += reference.byteCount
        }
        if !batch.isEmpty {
            try process(batch, membership: &membership)
        }
        return membership
    }

    private func makeSignedManifest(_ manifest: TimeMachineGenerationManifest) throws -> TimeMachineSignedManifest {
        var canonicalManifest = manifest
        canonicalManifest.createdAt = TimeMachineWireDate.canonical(manifest.createdAt)
        let manifestData = try Self.canonicalEncoder.encode(canonicalManifest)
        let digest = Self.sha256Hex(manifestData)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: manifestData,
            using: authenticationKey
        )
        return TimeMachineSignedManifest(
            manifest: canonicalManifest,
            manifestDigest: digest,
            authenticationCode: Data(authentication).base64EncodedString()
        )
    }

    private func validateManifest(
        _ manifest: TimeMachineGenerationManifest,
        previousManifest: TimeMachineGenerationManifest?,
        suppliedObjects: [String: TimeMachineObjectPayload]
    ) throws {
        try validateShardReferences(in: manifest)
        if let previousManifest {
            try validateShardReferences(in: previousManifest)
        }
        let previousByPrefix = Dictionary(
            uniqueKeysWithValues: (previousManifest?.fileShards ?? []).map { ($0.prefix, $0) }
        )
        let changedReferences = manifest.fileShards.filter {
            previousByPrefix[$0.prefix] != $0
        }
        var changedManifest = manifest
        changedManifest.fileShards = changedReferences
        let files = try loadFiles(from: changedManifest, suppliedObjects: suppliedObjects)
        var previousChangedFiles: [TimeMachineRemoteFile] = []
        if var previousManifest {
            let changedPrefixes = Set(changedReferences.map(\.prefix))
            previousManifest.fileShards = previousManifest.fileShards.filter {
                changedPrefixes.contains($0.prefix)
            }
            previousChangedFiles = try loadFiles(from: previousManifest, suppliedObjects: [:])
        }
        let previouslyAuthenticatedReferences = Set(
            previousChangedFiles.flatMap(\.chunks)
        )
        var referencedDigests = Set(manifest.fileShards.map(\.objectDigest))
        for file in files {
            for reference in file.chunks {
                referencedDigests.insert(reference.objectDigest)
                if let supplied = suppliedObjects[reference.objectDigest] {
                    let suppliedData = try supplied.loadData()
                    guard
                        suppliedData.count == reference.byteCount,
                        Self.sha256Hex(suppliedData) == reference.objectDigest
                    else {
                        throw TimeMachineObjectStoreError.invalidManifest
                    }
                    continue
                }
                if previouslyAuthenticatedReferences.contains(reference) {
                    continue
                }
                let remote = try transport.readObject(at: objectPath(forDigest: reference.objectDigest))
                let actualDigest = Self.sha256Hex(remote)
                guard actualDigest == reference.objectDigest, remote.count == reference.byteCount else {
                    throw TimeMachineObjectStoreError.invalidObjectDigest(
                        expected: reference.objectDigest,
                        actual: actualDigest
                    )
                }
            }
        }
        guard Set(suppliedObjects.keys).isSubset(of: referencedDigests) else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
    }

    private func loadFiles(
        from manifest: TimeMachineGenerationManifest,
        suppliedObjects: [String: TimeMachineObjectPayload]
    ) throws -> [TimeMachineRemoteFile] {
        try validateShardReferences(in: manifest)
        let references = manifest.fileShards

        var files: [TimeMachineRemoteFile] = []
        var loadedChunkReferenceCount = 0
        func appendValidated(_ decodedFiles: [TimeMachineRemoteFile]) throws {
            let (nextFileCount, fileCountOverflowed) = files.count
                .addingReportingOverflow(decodedFiles.count)
            var nextChunkReferenceCount = loadedChunkReferenceCount
            for file in decodedFiles {
                let (nextCount, overflowed) = nextChunkReferenceCount
                    .addingReportingOverflow(file.chunks.count)
                guard
                    !overflowed,
                    nextCount <= Self.maximumChunkReferenceCount
                else {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                nextChunkReferenceCount = nextCount
            }
            guard
                !fileCountOverflowed,
                nextFileCount <= Self.maximumRemoteFileCount
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            files.append(contentsOf: decodedFiles)
            loadedChunkReferenceCount = nextChunkReferenceCount
        }
        var batch: [TimeMachineFileShardReference] = []
        var batchBytes = 0
        for reference in references {
            if let supplied = suppliedObjects[reference.objectDigest] {
                try appendValidated(
                    try decodeFileShard(
                        reference,
                        data: supplied.loadData()
                    )
                )
                continue
            }
            if !batch.isEmpty, batchBytes + reference.byteCount > 64 * 1_048_576 {
                try appendValidated(try loadRemoteFileShardBatch(batch))
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
            batch.append(reference)
            batchBytes += reference.byteCount
        }
        if !batch.isEmpty {
            try appendValidated(try loadRemoteFileShardBatch(batch))
        }
        try Self.validateFileStructure(files)
        return files.sorted { $0.path < $1.path }
    }

    /// Decode each bounded transport batch before requesting the next one, so
    /// reopening a large image never retains every raw shard payload in
    /// addition to the parsed file map.
    private func loadRemoteFileShardBatch(
        _ references: [TimeMachineFileShardReference]
    ) throws -> [TimeMachineRemoteFile] {
        let paths = references.map { objectPath(forDigest: $0.objectDigest) }
        let objects = try transport.readObjects(at: paths)
        var files: [TimeMachineRemoteFile] = []
        for reference in references {
            let path = objectPath(forDigest: reference.objectDigest)
            guard let data = objects[path] else {
                throw TimeMachineObjectStoreError.objectNotFound(path)
            }
            files.append(contentsOf: try decodeFileShard(reference, data: data))
        }
        return files
    }

    private func decodeFileShard(
        _ reference: TimeMachineFileShardReference,
        data: Data
    ) throws -> [TimeMachineRemoteFile] {
        let digest = Self.sha256Hex(data)
        guard digest == reference.objectDigest else {
            throw TimeMachineObjectStoreError.invalidObjectDigest(
                expected: reference.objectDigest,
                actual: digest
            )
        }
        guard
            data.count == reference.byteCount,
            let shard = try? Self.canonicalDecoder.decode(TimeMachineFileShard.self, from: data),
            shard.formatVersion == TimeMachineFileShard.formatVersion,
            shard.storeID == storeID,
            shard.prefix == reference.prefix,
            shard.files.count == reference.fileCount,
            shard.files.allSatisfy({ Self.fileShardPrefix(for: $0.path) == reference.prefix })
        else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        try Self.validateFileStructure(shard.files)
        return shard.files
    }

    private func validateShardReferences(in manifest: TimeMachineGenerationManifest) throws {
        let references = manifest.fileShards
        let prefixes = references.map(\.prefix)
        var declaredFileCount = 0
        for reference in references {
            let (nextCount, overflowed) = declaredFileCount
                .addingReportingOverflow(reference.fileCount)
            guard
                !overflowed,
                nextCount <= Self.maximumRemoteFileCount
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            declaredFileCount = nextCount
        }
        guard
            manifest.formatVersion == TimeMachineGenerationManifest.formatVersion,
            manifest.storeID == storeID,
            manifest.chunkSizeBytes == TimeMachineRepositorySettings.chunkSizeBytes,
            references.count <= 4_096,
            Set(prefixes).count == prefixes.count,
            references == references.sorted(by: { $0.prefix < $1.prefix }),
            references.allSatisfy({ reference in
                Self.isFileShardPrefix(reference.prefix)
                    && Self.isSHA256Digest(reference.objectDigest)
                    && reference.byteCount > 0
                    && reference.byteCount <= 4 * 1_048_576
                    && reference.fileCount > 0
            })
        else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
    }

    private static func validateFileStructure(_ files: [TimeMachineRemoteFile]) throws {
        guard files.count <= maximumRemoteFileCount else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let paths = files.map(\.path)
        guard Set(paths).count == paths.count, paths.allSatisfy(isValidRelativeFilePath) else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let maximumLogicalBytes = UInt64(
            TimeMachineRepositorySettings.maximumImageCapacityBytes
                + 1_073_741_824
        )
        var totalLogicalBytes: UInt64 = 0
        var totalReferencedBytes: UInt64 = 0
        var totalChunkReferences = 0
        for file in files {
            let (nextLogicalBytes, logicalOverflow) = totalLogicalBytes.addingReportingOverflow(
                file.logicalSize
            )
            guard !logicalOverflow, nextLogicalBytes <= maximumLogicalBytes else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            totalLogicalBytes = nextLogicalBytes
            let indexes = file.chunks.map(\.index)
            let (nextChunkCount, chunkCountOverflowed) = totalChunkReferences
                .addingReportingOverflow(indexes.count)
            guard
                !chunkCountOverflowed,
                nextChunkCount <= maximumChunkReferenceCount
            else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            totalChunkReferences = nextChunkCount
            guard Set(indexes).count == indexes.count else {
                throw TimeMachineObjectStoreError.invalidManifest
            }
            for reference in file.chunks {
                guard
                    reference.byteCount > 0,
                    reference.byteCount <= TimeMachineRepositorySettings.chunkSizeBytes,
                    file.logicalSize > 0,
                    reference.index <= (file.logicalSize - 1) / UInt64(TimeMachineRepositorySettings.chunkSizeBytes),
                    isSHA256Digest(reference.objectDigest)
                else {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                let (nextReferencedBytes, referencedOverflow) = totalReferencedBytes
                    .addingReportingOverflow(UInt64(reference.byteCount))
                guard !referencedOverflow, nextReferencedBytes <= maximumLogicalBytes else {
                    throw TimeMachineObjectStoreError.invalidManifest
                }
                totalReferencedBytes = nextReferencedBytes
            }
        }
    }

    private static func isValidRelativeFilePath(_ path: String) -> Bool {
        TimeMachineRemotePathPolicy.isValid(path)
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }

    private static func fileShardPrefix(for path: String) -> String {
        String(sha256Hex(Data(path.utf8)).prefix(3))
    }

    private static func isFileShardPrefix(_ value: String) -> Bool {
        value.count == 3 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }

    private func decodeAndVerifySignedManifest(_ data: Data) throws -> TimeMachineSignedManifest {
        guard let signed = try? Self.canonicalDecoder.decode(TimeMachineSignedManifest.self, from: data) else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        let manifestData = try Self.canonicalEncoder.encode(signed.manifest)
        guard Self.sha256Hex(manifestData) == signed.manifestDigest else {
            throw TimeMachineObjectStoreError.invalidManifest
        }
        guard let suppliedAuthentication = Data(base64Encoded: signed.authenticationCode) else {
            throw TimeMachineObjectStoreError.invalidManifestAuthentication
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            suppliedAuthentication,
            authenticating: manifestData,
            using: authenticationKey
        ) else {
            throw TimeMachineObjectStoreError.invalidManifestAuthentication
        }
        return signed
    }

    private func encodeGarbageCollectionCandidate(
        _ candidate: TimeMachineGarbageCollectionCandidate
    ) throws -> Data {
        let candidateData = try Self.canonicalEncoder.encode(candidate)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: candidateData,
            using: authenticationKey
        )
        return try Self.canonicalEncoder.encode(
            TimeMachineSignedGarbageCollectionCandidate(
                candidate: candidate,
                candidateDigest: Self.sha256Hex(candidateData),
                authenticationCode: Data(authentication).base64EncodedString()
            )
        )
    }

    private func loadGarbageCollectionCandidate(
        at path: String,
        expectedObjectDigest: String
    ) throws -> TimeMachineGarbageCollectionCandidate {
        guard
            let signed = try? Self.canonicalDecoder.decode(
                TimeMachineSignedGarbageCollectionCandidate.self,
                from: transport.readObject(at: path)
            ),
            let authentication = Data(base64Encoded: signed.authenticationCode)
        else {
            throw TimeMachineObjectStoreError.invalidGarbageCollectionMarker
        }
        let candidateData = try Self.canonicalEncoder.encode(signed.candidate)
        guard
            signed.candidate.formatVersion == TimeMachineGarbageCollectionCandidate.formatVersion,
            signed.candidate.storeID == storeID,
            signed.candidate.objectDigest == expectedObjectDigest,
            signed.candidateDigest == Self.sha256Hex(candidateData),
            path == garbageCollectionMarkerPath(forDigest: expectedObjectDigest),
            HMAC<SHA256>.isValidAuthenticationCode(
                authentication,
                authenticating: candidateData,
                using: authenticationKey
            )
        else {
            throw TimeMachineObjectStoreError.invalidGarbageCollectionMarker
        }
        return signed.candidate
    }

    private func digestFromBlobPath(_ path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let digest = String(path.dropFirst(prefix.count))
        guard Self.isSHA256Digest(digest), path == objectPath(forDigest: digest) else {
            return nil
        }
        return digest
    }

    private func digestFromMarkerPath(_ path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(".json") else { return nil }
        let filename = String(path.dropFirst(prefix.count).dropLast(5))
        guard
            Self.isSHA256Digest(filename),
            path == garbageCollectionMarkerPath(forDigest: filename)
        else {
            return nil
        }
        return filename
    }

    private func objectPath(forDigest digest: String) -> String {
        let prefix = String(digest.prefix(2))
        return "\(namespace)/blobs/sha256/\(prefix)/\(digest)"
    }

    private func garbageCollectionMarkerPath(forDigest digest: String) -> String {
        let prefix = String(digest.prefix(2))
        return "\(namespace)/gc/candidates/\(prefix)/\(digest).json"
    }

    private func manifestPath(generation: UInt64, digest: String, writerID: UUID) -> String {
        let generationString = String(format: "%020llu", generation)
        return "\(namespace)/manifests/\(generationString)-\(writerID.uuidString.lowercased())-\(digest).json"
    }

    private func leasePath(_ lease: TimeMachineRemoteLease) -> String {
        let timestamp = Int64(lease.issuedAt.timeIntervalSince1970 * 1_000)
        return "\(namespace)/leases/\(String(format: "%020lld", timestamp))-\(lease.ownerID.uuidString.lowercased())-\(lease.nonce.uuidString.lowercased()).json"
    }

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let canonicalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

enum TimeMachineWireDate {
    /// The authenticated transport format encodes milliseconds. Canonicalizing
    /// before comparisons keeps an encode/decode round trip bit-for-bit stable;
    /// raw `Date()` values can otherwise differ by a fraction of a microsecond.
    static func canonical(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private struct TimeMachineDigestMembership {
    // Fixed at 32 MiB. False positives retain an unreferenced blob for a later
    // cleanup; inserted digests never produce false negatives.
    private static let wordCount = 4 * 1_048_576
    private static let hashCount = 5
    private var words = [UInt64](repeating: 0, count: Self.wordCount)

    mutating func insert(_ digest: String) {
        guard let hashes = hashes(for: digest) else { return }
        for index in 0..<Self.hashCount {
            let bit = (hashes.first &+ UInt64(index) &* hashes.second)
                % UInt64(Self.wordCount * 64)
            words[Int(bit / 64)] |= UInt64(1) << UInt64(bit % 64)
        }
    }

    func contains(_ digest: String) -> Bool {
        guard let hashes = hashes(for: digest) else { return true }
        for index in 0..<Self.hashCount {
            let bit = (hashes.first &+ UInt64(index) &* hashes.second)
                % UInt64(Self.wordCount * 64)
            if words[Int(bit / 64)] & (UInt64(1) << UInt64(bit % 64)) == 0 {
                return false
            }
        }
        return true
    }

    private func hashes(for digest: String) -> (first: UInt64, second: UInt64)? {
        guard digest.count == 64 else { return nil }
        let firstEnd = digest.index(digest.startIndex, offsetBy: 16)
        let secondEnd = digest.index(firstEnd, offsetBy: 16)
        guard
            let first = UInt64(digest[..<firstEnd], radix: 16),
            let rawSecond = UInt64(digest[firstEnd..<secondEnd], radix: 16)
        else {
            return nil
        }
        // An odd second hash traverses the power-of-two bit array without a
        // short even cycle.
        return (first, rawSecond | 1)
    }
}
