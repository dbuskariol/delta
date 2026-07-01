import Darwin
import Foundation

public protocol RepositoryLocking: Sendable {
    func acquire(repositoryID: UUID) throws -> RepositoryJobLock?
}

public final class RepositoryJobLock: @unchecked Sendable {
    private let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
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
        let directory = try lockDirectoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(repositoryID.uuidString).lock")
        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
}
