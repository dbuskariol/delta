import Darwin
import Foundation

public protocol RepositoryLocking: Sendable {
    func acquire(repositoryID: UUID) throws -> RepositoryJobLock?
}

public final class RepositoryJobLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        release()
    }

    /// Releases the process lock at an explicit ownership handoff. Most callers
    /// rely on deinitialization; Time Machine connection setup uses this after
    /// persisting `.preparing` so the long-lived storage service can become the
    /// destination-lock owner without a race in the durable lifecycle.
    func release() {
        stateLock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = nil
        stateLock.unlock()
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public struct RepositoryJobLockManager: RepositoryLocking {
    private var lockDirectoryProvider: @Sendable () throws -> URL

    public init(lockDirectoryProvider: (@Sendable () throws -> URL)? = nil) {
        self.lockDirectoryProvider = lockDirectoryProvider ?? {
            try AppDirectories.lockDirectory()
        }
    }

    public func acquire(repositoryID: UUID) throws -> RepositoryJobLock? {
        try acquireRepositoryLock(
            repositoryID: repositoryID,
            fileNameSuffix: "",
            lockDirectoryProvider: lockDirectoryProvider
        )
    }
}

/// Serializes privileged Time Machine connect/disconnect mutations separately
/// from the normal destination lock. The storage service owns the normal lock
/// for the entire mounted lifetime, so sharing it with system setup would make
/// the service and its caller wait on each other.
public struct TimeMachineSystemOperationLockManager: RepositoryLocking {
    private var lockDirectoryProvider: @Sendable () throws -> URL

    public init(lockDirectoryProvider: (@Sendable () throws -> URL)? = nil) {
        self.lockDirectoryProvider = lockDirectoryProvider ?? {
            try AppDirectories.lockDirectory()
        }
    }

    public func acquire(repositoryID: UUID) throws -> RepositoryJobLock? {
        try acquireRepositoryLock(
            repositoryID: repositoryID,
            fileNameSuffix: ".time-machine-system",
            lockDirectoryProvider: lockDirectoryProvider
        )
    }
}

private func acquireRepositoryLock(
    repositoryID: UUID,
    fileNameSuffix: String,
    lockDirectoryProvider: @Sendable () throws -> URL
) throws -> RepositoryJobLock? {
    let directory = try lockDirectoryProvider()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let directoryDescriptor = open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var directoryStatus = stat()
    guard fstat(directoryDescriptor, &directoryStatus) == 0 else {
        let validationError = errno
        close(directoryDescriptor)
        throw POSIXError(POSIXErrorCode(rawValue: validationError) ?? .EIO)
    }
    guard
        (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
        directoryStatus.st_uid == geteuid()
    else {
        close(directoryDescriptor)
        throw POSIXError(.EPERM)
    }
    guard fchmod(directoryDescriptor, S_IRWXU) == 0 else {
        let validationError = errno
        close(directoryDescriptor)
        throw POSIXError(POSIXErrorCode(rawValue: validationError) ?? .EIO)
    }
    close(directoryDescriptor)
    let lockURL = directory.appendingPathComponent(
        "\(repositoryID.uuidString)\(fileNameSuffix).lock"
    )
    let fileDescriptor = open(
        lockURL.path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    )
    guard fileDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var lockStatus = stat()
    guard fstat(fileDescriptor, &lockStatus) == 0 else {
        let validationError = errno
        close(fileDescriptor)
        throw POSIXError(POSIXErrorCode(rawValue: validationError) ?? .EIO)
    }
    guard
        (lockStatus.st_mode & S_IFMT) == S_IFREG,
        lockStatus.st_uid == geteuid()
    else {
        close(fileDescriptor)
        throw POSIXError(.EPERM)
    }
    guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        let validationError = errno
        close(fileDescriptor)
        throw POSIXError(POSIXErrorCode(rawValue: validationError) ?? .EIO)
    }

    if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
        return RepositoryJobLock(fileDescriptor: fileDescriptor)
    }

    let lockError = errno
    close(fileDescriptor)
    if lockError == EWOULDBLOCK {
        return nil
    }
    throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
}
