import Foundation

public enum ResticJSONParserError: Error, LocalizedError {
    case invalidSnapshotDate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSnapshotDate(value): "Invalid restore point date: \(value)."
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

    public func parseSnapshotEntries(from jsonLines: String) throws -> [ResticSnapshotEntry] {
        let decoder = JSONDecoder()
        var entries: [ResticSnapshotEntry] = []
        for line in jsonLines.split(whereSeparator: \.isNewline) {
            let data = Data(line.utf8)
            let envelope = try decoder.decode(RawResticLine.self, from: data)
            guard envelope.messageType == "node" || envelope.structType == "node" else {
                continue
            }
            let raw = try decoder.decode(RawSnapshotEntry.self, from: data)
            let path = raw.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                continue
            }
            entries.append(
                ResticSnapshotEntry(
                    name: raw.name.isEmpty ? Self.displayName(for: path) : raw.name,
                    path: path,
                    type: ResticSnapshotEntryType(resticType: raw.type),
                    size: raw.size,
                    modifiedAt: raw.mtime.flatMap(Self.parseResticDate)
                )
            )
        }
        return entries
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

    private static func displayName(for path: String) -> String {
        if path == "/" {
            return "/"
        }
        return URL(fileURLWithPath: path).lastPathComponent
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

private struct RawResticLine: Decodable {
    var messageType: String?
    var structType: String?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case structType = "struct_type"
    }
}

private struct RawSnapshotEntry: Decodable {
    var name: String
    var type: String
    var path: String
    var size: Int64?
    var mtime: String?
}
