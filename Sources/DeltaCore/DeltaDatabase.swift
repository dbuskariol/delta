import Foundation
import GRDB

public enum DeltaDatabaseError: Error, LocalizedError {
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPayload(table): "The stored payload in \(table) could not be decoded."
        }
    }
}

public final class DeltaDatabase: @unchecked Sendable {
    private let queue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.queue = try DatabaseQueue(path: url.path)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestampString(date))
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseTimestamp(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        try migrate()
    }

    public static func live() throws -> DeltaDatabase {
        try DeltaDatabase(url: AppDirectories.databaseURL())
    }

    public func saveRepository(_ repository: BackupRepository) throws {
        try save(repository, id: repository.id.uuidString, table: "repositories")
    }

    public func fetchRepositories() throws -> [BackupRepository] {
        try fetchAll(table: "repositories")
    }

    public func saveProfile(_ profile: BackupProfile) throws {
        try save(profile, id: profile.id.uuidString, table: "backup_profiles")
    }

    public func fetchProfiles() throws -> [BackupProfile] {
        try fetchAll(table: "backup_profiles")
    }

    public func saveJobRun(_ run: JobRun) throws {
        try save(run, id: run.id.uuidString, table: "job_runs")
    }

    public func fetchJobRuns(limit: Int = 100) throws -> [JobRun] {
        try fetchAll(table: "job_runs", limit: limit)
    }

    public func saveSnapshot(_ snapshot: ResticSnapshot, repositoryID: UUID) throws {
        try save(snapshot, id: snapshot.id, table: "snapshots", repositoryID: repositoryID.uuidString)
    }

    public func saveSnapshots(_ snapshots: [ResticSnapshot], repositoryID: UUID) throws {
        for snapshot in snapshots {
            try saveSnapshot(snapshot, repositoryID: repositoryID)
        }
    }

    public func fetchSnapshots(repositoryID: UUID? = nil) throws -> [ResticSnapshot] {
        try fetchAll(table: "snapshots", repositoryID: repositoryID?.uuidString)
    }

    public func fetchSnapshotsByRepository() throws -> [UUID: [ResticSnapshot]] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT repository_id, payload FROM snapshots ORDER BY updated_at DESC")
            var snapshotsByRepository: [UUID: [ResticSnapshot]] = [:]
            for row in rows {
                let repositoryIDString: String? = row["repository_id"]
                guard
                    let repositoryIDString,
                    let repositoryID = UUID(uuidString: repositoryIDString)
                else {
                    continue
                }
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("snapshots")
                }
                let snapshot = try decoder.decode(ResticSnapshot.self, from: data)
                snapshotsByRepository[repositoryID, default: []].append(snapshot)
            }
            return snapshotsByRepository
        }
    }

    public func saveRestoreRequest(_ request: RestoreRequest) throws {
        try save(request, id: request.id.uuidString, table: "restore_jobs")
    }

    public func fetchRestoreRequests(limit: Int = 100) throws -> [RestoreRequest] {
        try fetchAll(table: "restore_jobs", limit: limit)
    }

    public func appendEvent(_ event: EventLog) throws {
        try save(event, id: event.id.uuidString, table: "event_logs")
    }

    public func fetchEvents(limit: Int = 200) throws -> [EventLog] {
        try fetchAll(table: "event_logs", limit: limit)
    }

    public func deleteAll() throws {
        try queue.write { db in
            for table in Self.payloadTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    private func migrate() throws {
        try queue.write { db in
            for table in Self.payloadTables {
                try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS \(table) (
                    id TEXT PRIMARY KEY NOT NULL,
                    repository_id TEXT,
                    payload TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_\(table)_repository_id ON \(table)(repository_id)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_\(table)_updated_at ON \(table)(updated_at)")
            }
        }
    }

    private func save<T: Encodable>(
        _ value: T,
        id: String,
        table: String,
        repositoryID: String? = nil
    ) throws {
        let payloadData = try encoder.encode(value)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw DeltaDatabaseError.invalidPayload(table)
        }
        let now = Self.timestampString(Date())

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(table) (id, repository_id, payload, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    repository_id = excluded.repository_id,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [id, repositoryID, payload, now, now]
            )
        }
    }

    private func fetchAll<T: Decodable>(
        table: String,
        repositoryID: String? = nil,
        limit: Int? = nil
    ) throws -> [T] {
        try queue.read { db in
            let rows: [Row]
            if let repositoryID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT payload FROM \(table) WHERE repository_id = ? ORDER BY updated_at DESC",
                    arguments: [repositoryID]
                )
            } else if let limit {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT payload FROM \(table) ORDER BY updated_at DESC LIMIT ?",
                    arguments: [limit]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY updated_at DESC")
            }

            return try rows.map { row in
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload(table)
                }
                return try decoder.decode(T.self, from: data)
            }
        }
    }

    private static let payloadTables = [
        "repositories",
        "backup_profiles",
        "job_runs",
        "snapshots",
        "restore_jobs",
        "event_logs"
    ]

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
