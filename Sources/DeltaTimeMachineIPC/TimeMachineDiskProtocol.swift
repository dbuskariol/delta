import Darwin
import Foundation
import Security

public enum DeltaTimeMachineIPCIdentity {
    public static let teamIdentifier = "BJCVJ5G7MJ"
    public static let storageServiceIdentifier = "DeltaTimeMachineService"
    /// macOS supports Team-ID-prefixed App Groups without a separately
    /// provisioned container. Delta is Mac-only, and this group is used only
    /// for authenticated local IPC between the app, storage service, and FSKit
    /// extension; it is not a Keychain access group.
    public static let applicationGroupIdentifier = "\(teamIdentifier).deltatm"

    public static func designatedRequirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    public static func controlSocketURL(
        repositoryID: UUID,
        applicationGroupContainerURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let container: URL
        if let applicationGroupContainerURL {
            container = applicationGroupContainerURL.standardizedFileURL
        } else {
            guard let resolved = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
            ) else {
                throw TimeMachineDiskProtocolError.invalidSocketPath(
                    "The Time Machine IPC App Group is unavailable."
                )
            }
            container = resolved.standardizedFileURL
        }

        // Darwin's sockaddr_un path includes the complete home-directory path.
        // A compact, repository-derived 80-bit name leaves room for macOS
        // account names while the repository ID inside every signed request
        // remains the authoritative routing identity.
        var uuid = repositoryID.uuid
        let compactID = withUnsafeBytes(of: &uuid) { bytes in
            Data(bytes.prefix(10)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let socket = container
            .appendingPathComponent(".i", isDirectory: true)
            .appendingPathComponent("d\(compactID)", isDirectory: false)
        let address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !socket.path.isEmpty, socket.path.utf8.count < capacity else {
            throw TimeMachineDiskProtocolError.invalidSocketPath(socket.path)
        }
        return socket
    }
}

/// Stable source metadata shared by the app and its FSKit extension. The
/// repository UUID identifies the durable remote disk. The outer unary FSKit
/// filesystem is only one connection transport for the encrypted sparsebundle,
/// so its public container and volume identity is the mount-session UUID; the
/// inner APFS volume remains Time Machine's durable disk identity.
public enum DeltaTimeMachineFileSystemIdentity {
    public static let repositoryMarkerFileName = ".delta-repository-id"
    public static let mountSessionMarkerFileName = ".delta-mount-session"
}

public enum TimeMachineDiskProtocolVersion {
    public static let current = 1
}

public enum TimeMachineDiskProtocolLimits {
    public static let maximumHeaderBytes = 65_536
    public static let maximumPayloadBytes = 2 * 1_048_576
}

public struct TimeMachineDiskCodeSigningPeerValidator: Sendable {
    private let requirements: [String]

    public init(allowedIdentifiers: [String]) {
        requirements = allowedIdentifiers.map {
            DeltaTimeMachineIPCIdentity.designatedRequirement(identifier: $0)
        }
    }

    public func validate(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        let attributes = [
            kSecGuestAttributeAudit as String: auditToken
        ] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code
        else {
            return false
        }
        for requirementText in requirements {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                requirementText as CFString,
                [],
                &requirement
            ) == errSecSuccess, let requirement else {
                continue
            }
            if SecCodeCheckValidity(code, [], requirement) == errSecSuccess {
                return true
            }
        }
        return false
    }
}

public enum TimeMachineDiskOperation: String, Codable, Sendable {
    case read
    case write
    case create
    case truncate
    case remove
    case rename
    case synchronize
    case status
}

public struct TimeMachineDiskRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var repositoryID: UUID?
    public var operation: TimeMachineDiskOperation
    public var path: String?
    public var destinationPath: String?
    public var offset: UInt64?
    public var length: Int?
    public var wait: Bool?
    public var payloadLength: Int

    public init(
        operation: TimeMachineDiskOperation,
        protocolVersion: Int = TimeMachineDiskProtocolVersion.current,
        repositoryID: UUID? = nil,
        path: String? = nil,
        destinationPath: String? = nil,
        offset: UInt64? = nil,
        length: Int? = nil,
        wait: Bool? = nil,
        payloadLength: Int = 0
    ) {
        self.protocolVersion = protocolVersion
        self.repositoryID = repositoryID
        self.operation = operation
        self.path = path
        self.destinationPath = destinationPath
        self.offset = offset
        self.length = length
        self.wait = wait
        self.payloadLength = payloadLength
    }
}

public struct TimeMachineDiskResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var repositoryID: UUID?
    public var errorNumber: Int32
    public var message: String?
    public var payloadLength: Int
    public var generation: UInt64?
    public var cleanCacheBytes: Int64?
    public var dirtyCacheBytes: Int64?
    public var capacityBytes: Int64?
    public var usedBytes: Int64?

    public init(
        protocolVersion: Int = TimeMachineDiskProtocolVersion.current,
        repositoryID: UUID? = nil,
        errorNumber: Int32 = 0,
        message: String? = nil,
        payloadLength: Int = 0,
        generation: UInt64? = nil,
        cleanCacheBytes: Int64? = nil,
        dirtyCacheBytes: Int64? = nil,
        capacityBytes: Int64? = nil,
        usedBytes: Int64? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.repositoryID = repositoryID
        self.errorNumber = errorNumber
        self.message = message
        self.payloadLength = payloadLength
        self.generation = generation
        self.cleanCacheBytes = cleanCacheBytes
        self.dirtyCacheBytes = dirtyCacheBytes
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
    }
}

public struct TimeMachineDiskProtocolResult: Equatable, Sendable {
    public var response: TimeMachineDiskResponse
    public var payload: Data

    public init(response: TimeMachineDiskResponse, payload: Data = Data()) {
        self.response = response
        self.payload = payload
    }
}

public enum TimeMachineDiskProtocolError: Error, Equatable, LocalizedError {
    case invalidSocketPath(String)
    case disconnected
    case invalidFrame
    case unauthorizedPeer
    case incompatibleVersion(expected: Int, actual: Int)
    case unexpectedRepository(expected: UUID, actual: UUID?)
    case remote(errorNumber: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSocketPath(path):
            "The Time Machine service socket path is invalid: \(path)."
        case .disconnected:
            "Delta's Time Machine storage service is disconnected."
        case .invalidFrame:
            "Delta's Time Machine storage service returned an invalid response."
        case .unauthorizedPeer:
            "Delta could not authenticate the Time Machine storage service."
        case let .incompatibleVersion(expected, actual):
            "The Time Machine storage service protocol is incompatible (expected \(expected), found \(actual))."
        case let .unexpectedRepository(expected, actual):
            "The Time Machine storage service belongs to a different destination (expected \(expected.uuidString), found \(actual?.uuidString ?? "none"))."
        case let .remote(errorNumber, message):
            "The Time Machine storage service failed (\(errorNumber)): \(message)"
        }
    }
}

public typealias TimeMachineDiskPeerValidator = @Sendable (Data) -> Bool

public final class TimeMachineDiskProtocolClient: @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private let repositoryID: UUID
    private let peerValidator: TimeMachineDiskPeerValidator
    private var descriptor: Int32 = -1

    public init(
        socketPath: String,
        repositoryID: UUID,
        peerValidator: @escaping TimeMachineDiskPeerValidator
    ) {
        self.socketPath = socketPath
        self.repositoryID = repositoryID
        self.peerValidator = peerValidator
    }

    deinit {
        lock.lock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        lock.unlock()
    }

    public func perform(
        _ request: TimeMachineDiskRequest,
        payload: Data = Data()
    ) throws -> TimeMachineDiskProtocolResult {
        try lock.withLock {
            guard
                payload.count == request.payloadLength,
                request.protocolVersion == TimeMachineDiskProtocolVersion.current,
                request.repositoryID == nil || request.repositoryID == repositoryID
            else {
                throw TimeMachineDiskProtocolError.invalidFrame
            }
            // Every storage operation is defined to be idempotent for the
            // exact same request. Retry one authenticated connection when the
            // peer disappears after accepting a request but before its reply;
            // otherwise FSKit could roll back its placeholder after the local
            // service had already applied the matching namespace mutation.
            for attempt in 0...1 {
                do {
                    if descriptor < 0 {
                        descriptor = try TimeMachineUnixSocket.connect(
                            path: socketPath,
                            peerValidator: peerValidator
                        )
                    }
                    var authenticatedRequest = request
                    authenticatedRequest.repositoryID = repositoryID
                    try TimeMachineDiskFraming.write(authenticatedRequest, payload: payload, to: descriptor)
                    let result: (TimeMachineDiskResponse, Data) = try TimeMachineDiskFraming.read(
                        TimeMachineDiskResponse.self,
                        from: descriptor
                    )
                    guard result.0.payloadLength == result.1.count else {
                        throw TimeMachineDiskProtocolError.invalidFrame
                    }
                    guard result.0.protocolVersion == TimeMachineDiskProtocolVersion.current else {
                        throw TimeMachineDiskProtocolError.incompatibleVersion(
                            expected: TimeMachineDiskProtocolVersion.current,
                            actual: result.0.protocolVersion
                        )
                    }
                    guard result.0.repositoryID == repositoryID else {
                        throw TimeMachineDiskProtocolError.unexpectedRepository(
                            expected: repositoryID,
                            actual: result.0.repositoryID
                        )
                    }
                    if result.0.errorNumber != 0 {
                        throw TimeMachineDiskProtocolError.remote(
                            errorNumber: result.0.errorNumber,
                            message: result.0.message ?? "Unknown remote error"
                        )
                    }
                    return TimeMachineDiskProtocolResult(response: result.0, payload: result.1)
                } catch {
                    if descriptor >= 0 {
                        Darwin.close(descriptor)
                        descriptor = -1
                    }
                    if attempt == 0,
                       case TimeMachineDiskProtocolError.disconnected = error
                    {
                        continue
                    }
                    throw error
                }
            }
            throw TimeMachineDiskProtocolError.disconnected
        }
    }
}

public final class TimeMachineDiskProtocolServer: @unchecked Sendable {
    public typealias Handler = @Sendable (TimeMachineDiskRequest, Data) -> TimeMachineDiskProtocolResult

    private let socketPath: String
    private let handler: Handler
    private let peerValidator: TimeMachineDiskPeerValidator
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private struct SocketIdentity {
        var device: dev_t
        var inode: ino_t
    }
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: Set<Int32> = []
    private var socketIdentity: SocketIdentity?

    public init(
        socketPath: String,
        peerValidator: @escaping TimeMachineDiskPeerValidator,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.peerValidator = peerValidator
        self.handler = handler
        self.queue = DispatchQueue(label: "com.delta.backup.time-machine.socket", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try onQueue {
            guard listener < 0 else { return }
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryStatus = stat()
            guard
                stat(directory.path, &directoryStatus) == 0,
                (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
                directoryStatus.st_uid == geteuid(),
                Darwin.chmod(directory.path, S_IRWXU) == 0
            else {
                throw POSIXError(.EPERM)
            }
            try removeStaleSocketIfPresent()
            let descriptor = try TimeMachineUnixSocket.bindAndListen(path: socketPath)
            do {
                socketIdentity = try validatedSocketIdentity(
                    requiresPrivatePermissions: false
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            guard Darwin.lchmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                let permissionError = errno
                Darwin.close(descriptor)
                removeCurrentOwnedSocket()
                throw POSIXError(POSIXError.Code(rawValue: permissionError) ?? .EIO)
            }
            let identity: SocketIdentity
            do {
                identity = try validatedSocketIdentity(
                    requiresPrivatePermissions: true
                )
            } catch {
                Darwin.close(descriptor)
                removeCurrentOwnedSocket()
                throw error
            }
            socketIdentity = identity
            listener = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptAvailableConnections()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        onQueue {
            listener = -1
            source?.cancel()
            source = nil
            for client in clients {
                _ = Darwin.shutdown(client, SHUT_RDWR)
            }
            removeCurrentOwnedSocket()
        }
    }

    private func removeStaleSocketIfPresent() throws {
        var existing = stat()
        guard Darwin.lstat(socketPath, &existing) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        guard
            (existing.st_mode & S_IFMT) == S_IFSOCK,
            existing.st_uid == geteuid(),
            (existing.st_mode & 0o077) == 0
        else {
            throw POSIXError(.EPERM)
        }
        guard Darwin.unlink(socketPath) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    private func validatedSocketIdentity(
        requiresPrivatePermissions: Bool
    ) throws -> SocketIdentity {
        var status = stat()
        guard
            Darwin.lstat(socketPath, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFSOCK,
            status.st_uid == geteuid(),
            !requiresPrivatePermissions
                || (status.st_mode & 0o777) == (S_IRUSR | S_IWUSR)
        else {
            throw POSIXError(.EPERM)
        }
        return SocketIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func removeCurrentOwnedSocket() {
        defer { socketIdentity = nil }
        guard let expected = socketIdentity else { return }
        var current = stat()
        guard
            Darwin.lstat(socketPath, &current) == 0,
            (current.st_mode & S_IFMT) == S_IFSOCK,
            current.st_uid == geteuid(),
            current.st_dev == expected.device,
            current.st_ino == expected.inode
        else {
            return
        }
        _ = Darwin.unlink(socketPath)
    }

    private func acceptAvailableConnections() {
        while listener >= 0 {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            var peerUser = uid_t()
            var peerGroup = gid_t()
            var peerToken = audit_token_t()
            var peerTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
            guard
                (try? TimeMachineUnixSocket.preventSIGPIPE(on: client)) != nil,
                getpeereid(client, &peerUser, &peerGroup) == 0,
                peerUser == geteuid(),
                getsockopt(
                    client,
                    SOL_LOCAL,
                    LOCAL_PEERTOKEN,
                    &peerToken,
                    &peerTokenSize
                ) == 0,
                peerTokenSize == MemoryLayout<audit_token_t>.size,
                peerValidator(withUnsafeBytes(of: peerToken) { Data($0) })
            else {
                Darwin.close(client)
                continue
            }
            let clientFlags = fcntl(client, F_GETFL)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            clients.insert(client)
            DispatchQueue.global(qos: .userInitiated).async { [weak self, handler] in
                defer {
                    if let self {
                        self.finishClient(client)
                    } else {
                        Darwin.close(client)
                    }
                }
                // DiskImages keeps this socket open for the life of an attached
                // image. Give every frame its own autorelease lifetime so the
                // temporary Foundation Data and JSON objects produced by a long
                // sequence of small reads do not accumulate until detach.
                while true {
                    let servedFrame = autoreleasepool(invoking: {
                        do {
                            let incoming: (TimeMachineDiskRequest, Data) = try TimeMachineDiskFraming.read(
                                TimeMachineDiskRequest.self,
                                from: client
                            )
                            guard incoming.0.protocolVersion == TimeMachineDiskProtocolVersion.current else {
                                try TimeMachineDiskFraming.write(
                                    TimeMachineDiskResponse(
                                        repositoryID: incoming.0.repositoryID,
                                        errorNumber: EPROTONOSUPPORT,
                                        message: "Unsupported Time Machine protocol version."
                                    ),
                                    payload: Data(),
                                    to: client
                                )
                                return false
                            }
                            guard incoming.0.payloadLength == incoming.1.count else {
                                try TimeMachineDiskFraming.write(
                                    TimeMachineDiskResponse(
                                        repositoryID: incoming.0.repositoryID,
                                        errorNumber: EPROTO,
                                        message: "Invalid Time Machine request payload."
                                    ),
                                    payload: Data(),
                                    to: client
                                )
                                return false
                            }
                            let result = handler(incoming.0, incoming.1)
                            try TimeMachineDiskFraming.write(result.response, payload: result.payload, to: client)
                            return true
                        } catch {
                            return false
                        }
                    })
                    guard servedFrame else { return }
                }
            }
        }
    }

    private func finishClient(_ client: Int32) {
        let owned = onQueue {
            clients.remove(client) != nil
        }
        if owned {
            Darwin.close(client)
        }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}

private enum TimeMachineDiskFraming {
    static func write<Value: Encodable>(_ header: Value, payload: Data, to descriptor: Int32) throws {
        let encoded = try JSONEncoder().encode(header)
        guard
            encoded.count <= TimeMachineDiskProtocolLimits.maximumHeaderBytes,
            payload.count <= TimeMachineDiskProtocolLimits.maximumPayloadBytes
        else {
            throw TimeMachineDiskProtocolError.invalidFrame
        }
        var headerLength = UInt32(encoded.count).bigEndian
        var payloadLength = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &headerLength) { try writeAll(Data($0), to: descriptor) }
        try withUnsafeBytes(of: &payloadLength) { try writeAll(Data($0), to: descriptor) }
        try writeAll(encoded, to: descriptor)
        try writeAll(payload, to: descriptor)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from descriptor: Int32) throws -> (Value, Data) {
        let lengths = try readExactly(8, from: descriptor)
        let headerLength = lengths.prefix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let payloadLength = lengths.suffix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard
            headerLength <= UInt32(TimeMachineDiskProtocolLimits.maximumHeaderBytes),
            payloadLength <= UInt32(TimeMachineDiskProtocolLimits.maximumPayloadBytes)
        else {
            throw TimeMachineDiskProtocolError.invalidFrame
        }
        let headerData = try readExactly(Int(headerLength), from: descriptor)
        let payload = try readExactly(Int(payloadLength), from: descriptor)
        guard let header = try? JSONDecoder().decode(Value.self, from: headerData) else {
            throw TimeMachineDiskProtocolError.invalidFrame
        }
        return (header, payload)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw TimeMachineDiskProtocolError.disconnected
                }
                offset += written
            }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR {
                    continue
                }
                guard received > 0 else {
                    throw TimeMachineDiskProtocolError.disconnected
                }
                offset += received
            }
        }
        return data
    }
}

private enum TimeMachineUnixSocket {
    static func connect(
        path: String,
        peerValidator: TimeMachineDiskPeerValidator
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TimeMachineDiskProtocolError.disconnected }
        do {
            try preventSIGPIPE(on: descriptor)
            var address = try makeAddress(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw TimeMachineDiskProtocolError.disconnected
            }
            var peerUser = uid_t()
            var peerGroup = gid_t()
            var peerToken = audit_token_t()
            var peerTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
            guard
                getpeereid(descriptor, &peerUser, &peerGroup) == 0,
                peerUser == geteuid(),
                getsockopt(
                    descriptor,
                    SOL_LOCAL,
                    LOCAL_PEERTOKEN,
                    &peerToken,
                    &peerTokenSize
                ) == 0,
                peerTokenSize == MemoryLayout<audit_token_t>.size,
                peerValidator(withUnsafeBytes(of: peerToken) { Data($0) })
            else {
                throw TimeMachineDiskProtocolError.unauthorizedPeer
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func bindAndListen(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var flags = fcntl(descriptor, F_GETFL)
            flags |= O_NONBLOCK
            _ = fcntl(descriptor, F_SETFL, flags)
            var address = try makeAddress(path: path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 32) == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// A peer can disappear between framing a request and writing its reply.
    /// Darwin otherwise delivers SIGPIPE and can terminate the whole FSKit or
    /// storage-service process instead of returning the actionable EPIPE.
    static func preventSIGPIPE(on descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path)
        guard !path.isEmpty, path.utf8.count < maximum else {
            throw TimeMachineDiskProtocolError.invalidSocketPath(path)
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximum) { characters in
                path.withCString { source in
                    strncpy(characters, source, maximum - 1)
                }
            }
        }
        return address
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
