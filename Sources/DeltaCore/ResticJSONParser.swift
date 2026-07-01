import Foundation

public enum ResticJSONParserError: Error, LocalizedError {
    case invalidSnapshotDate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSnapshotDate(value): "Invalid restic snapshot date: \(value)."
        }
    }
}

public struct ResticJSONParser: Sendable {
    public init() {}

    public func parseSnapshots(from json: String) throws -> [ResticSnapshot] {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let rawSnapshots = try decoder.decode([RawSnapshot].self, from: data)
        return try rawSnapshots.map { raw in
            guard let date = Self.parseResticDate(raw.time) else {
                throw ResticJSONParserError.invalidSnapshotDate(raw.time)
            }
            return ResticSnapshot(
                id: raw.id,
                time: date,
                tree: raw.tree,
                paths: raw.paths,
                hostname: raw.hostname,
                username: raw.username,
                tags: raw.tags ?? []
            )
        }
    }

    private static func parseResticDate(_ value: String) -> Date? {
        for formatter in makeDateFormatters() {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func makeDateFormatters() -> [ISO8601DateFormatter] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return [fractional, plain]
    }
}

private struct RawSnapshot: Decodable {
    var id: String
    var time: String
    var tree: String?
    var paths: [String]
    var hostname: String?
    var username: String?
    var tags: [String]?
}
