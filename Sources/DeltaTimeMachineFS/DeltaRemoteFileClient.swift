import DeltaTimeMachineIPC
import Foundation
import OSLog

final class DeltaRemoteFileClient: @unchecked Sendable {
    private let client: TimeMachineDiskProtocolClient
    let capacityBytes: Int64

    init(rootPath: String, repositoryID: UUID) throws {
        let socketPath = try DeltaTimeMachineIPCIdentity.controlSocketURL(
            repositoryID: repositoryID
        ).path
        let peerValidator = TimeMachineDiskCodeSigningPeerValidator(
            allowedIdentifiers: [DeltaTimeMachineIPCIdentity.storageServiceIdentifier]
        )
        client = TimeMachineDiskProtocolClient(
            socketPath: socketPath,
            repositoryID: repositoryID,
            peerValidator: {
                let isTrusted = peerValidator.validate(auditToken: $0)
                if !isTrusted {
                    Logger.passthroughfs.error(
                        "Rejected an unauthenticated Time Machine storage-service connection."
                    )
                }
                return isTrusted
            }
        )
        let status: TimeMachineDiskProtocolResult
        do {
            status = try client.perform(TimeMachineDiskRequest(operation: .status))
        } catch {
            Logger.passthroughfs.error(
                "Could not open the authenticated Time Machine storage channel: \(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        guard let capacityBytes = status.response.capacityBytes, capacityBytes > 0 else {
            throw POSIXError(.EIO)
        }
        self.capacityBytes = capacityBytes
    }

    func read(path: String, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset <= UInt64.max - UInt64(length) else {
            throw POSIXError(.EINVAL)
        }
        var output = Data()
        output.reserveCapacity(
            min(length, TimeMachineDiskProtocolLimits.maximumPayloadBytes)
        )
        while output.count < length {
            let requestLength = min(
                length - output.count,
                TimeMachineDiskProtocolLimits.maximumPayloadBytes
            )
            do {
                let payload = try perform(
                    TimeMachineDiskRequest(
                        operation: .read,
                        path: path,
                        offset: offset + UInt64(output.count),
                        length: requestLength
                    )
                ).payload
                guard payload.count <= requestLength else {
                    throw POSIXError(.EIO)
                }
                output.append(payload)
                if payload.count < requestLength { break }
            } catch {
                if !output.isEmpty { return output }
                throw error
            }
        }
        return output
    }

    func write(path: String, offset: UInt64, data: Data) throws -> Int {
        guard offset <= UInt64.max - UInt64(data.count) else {
            throw POSIXError(.EINVAL)
        }
        var written = 0
        while written < data.count {
            let count = min(
                data.count - written,
                TimeMachineDiskProtocolLimits.maximumPayloadBytes
            )
            let payload = data.subdata(in: written..<(written + count))
            do {
                _ = try perform(
                    TimeMachineDiskRequest(
                        operation: .write,
                        path: path,
                        offset: offset + UInt64(written),
                        payloadLength: payload.count
                    ),
                    payload: payload
                )
                written += count
            } catch {
                if written > 0 { return written }
                throw error
            }
        }
        return written
    }

    func create(path: String, size: UInt64) throws {
        _ = try perform(
            TimeMachineDiskRequest(operation: .create, path: path, offset: size)
        )
    }

    func truncate(path: String, size: UInt64) throws {
        _ = try perform(
            TimeMachineDiskRequest(operation: .truncate, path: path, offset: size)
        )
    }

    func remove(path: String) throws {
        _ = try perform(TimeMachineDiskRequest(operation: .remove, path: path))
    }

    func rename(path: String, to destinationPath: String) throws {
        _ = try perform(
            TimeMachineDiskRequest(
                operation: .rename,
                path: path,
                destinationPath: destinationPath
            )
        )
    }

    func synchronize(wait: Bool) throws {
        _ = try perform(
            TimeMachineDiskRequest(operation: .synchronize, wait: wait)
        )
    }

    func storageStatus() throws -> (capacityBytes: Int64, usedBytes: Int64) {
        let status = try perform(TimeMachineDiskRequest(operation: .status)).response
        guard
            let reportedCapacity = status.capacityBytes,
            reportedCapacity > 0,
            let usedBytes = status.usedBytes,
            usedBytes >= 0
        else {
            throw POSIXError(.EIO)
        }
        return (reportedCapacity, usedBytes)
    }

    private func perform(
        _ request: TimeMachineDiskRequest,
        payload: Data = Data()
    ) throws -> TimeMachineDiskProtocolResult {
        do {
            return try client.perform(request, payload: payload)
        } catch let TimeMachineDiskProtocolError.remote(errorNumber, _) {
            throw POSIXError(POSIXError.Code(rawValue: errorNumber) ?? .EIO)
        } catch {
            throw POSIXError(.EIO)
        }
    }
}
