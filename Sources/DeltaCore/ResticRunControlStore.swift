import Foundation

public struct ResticRunStopRequest: Codable, Equatable, Sendable {
    public var jobID: UUID
    public var reason: ResticRunStopReason
    public var createdAt: Date

    public init(jobID: UUID, reason: ResticRunStopReason, createdAt: Date = Date()) {
        self.jobID = jobID
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct ResticRunControlStore: Sendable {
    private let directoryProvider: @Sendable () throws -> URL

    public init(directoryProvider: @escaping @Sendable () throws -> URL = { try AppDirectories.controlDirectory() }) {
        self.directoryProvider = directoryProvider
    }

    public func requestStop(jobID: UUID, reason: ResticRunStopReason) throws {
        let request = ResticRunStopRequest(jobID: jobID, reason: reason)
        let data = try Self.encoder().encode(request)
        try data.write(to: requestURL(for: jobID), options: [.atomic])
    }

    public func stopRequest(for jobID: UUID) throws -> ResticRunStopRequest? {
        let url = try requestURL(for: jobID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let request = try Self.decoder().decode(ResticRunStopRequest.self, from: data)
        guard request.jobID == jobID else {
            return nil
        }
        return request
    }

    public func stopReason(for jobID: UUID) -> ResticRunStopReason? {
        try? stopRequest(for: jobID)?.reason
    }

    public func clearStopRequest(jobID: UUID) {
        guard let url = try? requestURL(for: jobID) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func requestURL(for jobID: UUID) throws -> URL {
        let directory = try directoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(jobID.uuidString).json", isDirectory: false)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
