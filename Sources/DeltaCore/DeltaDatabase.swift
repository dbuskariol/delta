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

public struct OperationalHistoryPruneResult: Equatable, Sendable {
    public var deletedJobRuns: Int
    public var deletedJobLogs: Int
    public var deletedRestoreRequests: Int
    public var deletedEvents: Int

    public init(
        deletedJobRuns: Int = 0,
        deletedJobLogs: Int = 0,
        deletedRestoreRequests: Int = 0,
        deletedEvents: Int = 0
    ) {
        self.deletedJobRuns = deletedJobRuns
        self.deletedJobLogs = deletedJobLogs
        self.deletedRestoreRequests = deletedRestoreRequests
        self.deletedEvents = deletedEvents
    }

    public var totalDeleted: Int {
        deletedJobRuns + deletedJobLogs + deletedRestoreRequests + deletedEvents
    }
}

public final class DeltaDatabase: @unchecked Sendable {
    private let queue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.journalMode = .wal
        self.queue = try DatabaseQueue(path: url.path, configuration: configuration)
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

    public func deleteRepository(id: UUID) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM repositories WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM snapshots WHERE repository_id = ?", arguments: [id.uuidString])
        }
    }

    public func saveProfile(_ profile: BackupProfile) throws {
        try save(profile, id: profile.id.uuidString, table: "backup_profiles")
    }

    public func fetchProfiles() throws -> [BackupProfile] {
        try fetchAll(table: "backup_profiles")
    }

    public func deleteProfile(id: UUID) throws {
        try delete(id: id.uuidString, table: "backup_profiles")
    }

    public func saveJobRun(_ run: JobRun) throws {
        try save(run, id: run.id.uuidString, table: "job_runs")
    }

    public func fetchJobRuns(limit: Int = 100) throws -> [JobRun] {
        try fetchAll(table: "job_runs", limit: limit)
    }

    public func updateJobRunProgress(id: UUID, progressSnapshot: ResticProgressSnapshot) throws {
        try queue.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT payload FROM job_runs WHERE id = ?",
                    arguments: [id.uuidString]
                )
            else {
                return
            }
            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8) else {
                throw DeltaDatabaseError.invalidPayload("job_runs")
            }
            var job = try decoder.decode(JobRun.self, from: data)
            guard job.status == .running else {
                return
            }
            job.progressSnapshot = progressSnapshot
            let updatedPayload = try encodedPayload(job, table: "job_runs")
            try db.execute(
                sql: "UPDATE job_runs SET payload = ?, updated_at = ? WHERE id = ?",
                arguments: [updatedPayload, Self.timestampString(Date()), id.uuidString]
            )
        }
    }

    public func appendJobLog(_ entry: JobLogEntry) throws {
        let payloadData = try encoder.encode(entry)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw DeltaDatabaseError.invalidPayload("job_logs")
        }
        let timestamp = Self.timestampString(entry.date)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO job_logs (id, job_id, repository_id, payload, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [entry.id.uuidString, entry.jobID.uuidString, entry.repositoryID.uuidString, payload, timestamp]
            )
        }
    }

    public func fetchJobLogs(jobID: UUID? = nil, repositoryID: UUID? = nil, limit: Int = 500) throws -> [JobLogEntry] {
        try queue.read { db in
            let rows: [Row]
            if let jobID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT payload FROM job_logs WHERE job_id = ? ORDER BY created_at DESC LIMIT ?",
                    arguments: [jobID.uuidString, limit]
                )
            } else if let repositoryID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT payload FROM job_logs WHERE repository_id = ? ORDER BY created_at DESC LIMIT ?",
                    arguments: [repositoryID.uuidString, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT payload FROM job_logs ORDER BY created_at DESC LIMIT ?",
                    arguments: [limit]
                )
            }

            return try rows.reversed().map { row in
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("job_logs")
                }
                return try decoder.decode(JobLogEntry.self, from: data)
            }
        }
    }

    public func saveSnapshot(_ snapshot: ResticSnapshot, repositoryID: UUID) throws {
        let payload = try encodedPayload(snapshot, table: "snapshots")
        let timestamp = Self.timestampString(Date())
        try queue.write { db in
            try upsertSnapshot(
                id: snapshot.id,
                repositoryID: repositoryID.uuidString,
                payload: payload,
                timestamp: timestamp,
                db: db
            )
        }
    }

    public func saveSnapshots(_ snapshots: [ResticSnapshot], repositoryID: UUID) throws {
        let encodedSnapshots = try snapshots.map { snapshot in
            let payload = try encodedPayload(snapshot, table: "snapshots")
            return (id: snapshot.id, payload: payload)
        }
        let timestamp = Self.timestampString(Date())
        let repositoryIDString = repositoryID.uuidString

        try queue.write { db in
            try db.execute(sql: "DELETE FROM snapshots WHERE repository_id = ?", arguments: [repositoryIDString])
            for snapshot in encodedSnapshots {
                try upsertSnapshot(
                    id: snapshot.id,
                    repositoryID: repositoryIDString,
                    payload: snapshot.payload,
                    timestamp: timestamp,
                    db: db
                )
            }
        }
    }

    public func fetchSnapshots(repositoryID: UUID? = nil) throws -> [ResticSnapshot] {
        try fetchAll(table: "snapshots", repositoryID: repositoryID?.uuidString)
            .sorted { $0.time > $1.time }
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
            for repositoryID in snapshotsByRepository.keys {
                snapshotsByRepository[repositoryID]?.sort { $0.time > $1.time }
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

    public func pruneOperationalHistory(
        olderThan cutoff: Date,
        minimumRecentJobs: Int = 100
    ) throws -> OperationalHistoryPruneResult {
        let cutoffString = Self.timestampString(cutoff)
        let retainedJobCount = max(0, minimumRecentJobs)

        return try queue.write { db in
            let oldLogCount = try count(
                db,
                sql: "SELECT COUNT(*) FROM job_logs WHERE created_at < ?",
                arguments: [cutoffString]
            )
            try db.execute(sql: "DELETE FROM job_logs WHERE created_at < ?", arguments: [cutoffString])

            let oldJobCount = try count(
                db,
                sql: """
                SELECT COUNT(*) FROM job_runs
                WHERE updated_at < ?
                  AND id NOT IN (
                    SELECT id FROM job_runs ORDER BY updated_at DESC LIMIT ?
                  )
                """,
                arguments: [cutoffString, retainedJobCount]
            )
            try db.execute(
                sql: """
                DELETE FROM job_runs
                WHERE updated_at < ?
                  AND id NOT IN (
                    SELECT id FROM job_runs ORDER BY updated_at DESC LIMIT ?
                  )
                """,
                arguments: [cutoffString, retainedJobCount]
            )

            let orphanLogCount = try count(
                db,
                sql: "SELECT COUNT(*) FROM job_logs WHERE job_id NOT IN (SELECT id FROM job_runs)"
            )
            try db.execute(sql: "DELETE FROM job_logs WHERE job_id NOT IN (SELECT id FROM job_runs)")

            let restoreRequestCount = try count(
                db,
                sql: "SELECT COUNT(*) FROM restore_jobs WHERE updated_at < ?",
                arguments: [cutoffString]
            )
            try db.execute(sql: "DELETE FROM restore_jobs WHERE updated_at < ?", arguments: [cutoffString])

            let eventCount = try count(
                db,
                sql: "SELECT COUNT(*) FROM event_logs WHERE updated_at < ?",
                arguments: [cutoffString]
            )
            try db.execute(sql: "DELETE FROM event_logs WHERE updated_at < ?", arguments: [cutoffString])

            return OperationalHistoryPruneResult(
                deletedJobRuns: oldJobCount,
                deletedJobLogs: oldLogCount + orphanLogCount,
                deletedRestoreRequests: restoreRequestCount,
                deletedEvents: eventCount
            )
        }
    }

    public func deleteAll() throws {
        try queue.write { db in
            for table in Self.payloadTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "DELETE FROM job_logs")
        }
    }

    private func delete(id: String, table: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
        }
    }

    private func count(_ db: Database, sql: String, arguments: StatementArguments = StatementArguments()) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    private func migrate() throws {
        try queue.write { db in
            for table in Self.genericPayloadTables {
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
            try Self.ensureSnapshotsTable(db)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS job_logs (
                id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT NOT NULL,
                repository_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_job_id ON job_logs(job_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_repository_id ON job_logs(repository_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_created_at ON job_logs(created_at)")
        }
    }

    private static func ensureSnapshotsTable(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(snapshots)")
        if rows.isEmpty {
            try createSnapshotsTable(db)
            return
        }

        let primaryKeyColumns = rows
            .compactMap { row -> (position: Int, name: String)? in
                let position: Int = row["pk"]
                guard position > 0 else {
                    return nil
                }
                let name: String = row["name"]
                return (position, name)
            }
            .sorted { $0.position < $1.position }
            .map(\.name)

        guard primaryKeyColumns != ["id", "repository_id"] else {
            try createSnapshotsIndexes(db)
            return
        }

        try db.execute(sql: "DROP TABLE snapshots")
        try createSnapshotsTable(db)
    }

    private static func createSnapshotsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS snapshots (
                id TEXT NOT NULL,
                repository_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (id, repository_id)
            )
            """)
        try createSnapshotsIndexes(db)
    }

    private static func createSnapshotsIndexes(_ db: Database) throws {
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_snapshots_repository_id ON snapshots(repository_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_snapshots_updated_at ON snapshots(updated_at)")
    }

    private func save<T: Encodable>(
        _ value: T,
        id: String,
        table: String,
        repositoryID: String? = nil
    ) throws {
        let payload = try encodedPayload(value, table: table)
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

    private func upsertSnapshot(
        id: String,
        repositoryID: String,
        payload: String,
        timestamp: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO snapshots (id, repository_id, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id, repository_id) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """,
            arguments: [id, repositoryID, payload, timestamp, timestamp]
        )
    }

    private func encodedPayload<T: Encodable>(_ value: T, table: String) throws -> String {
        let payloadData = try encoder.encode(value)
        guard let payload = String(data: payloadData, encoding: .utf8) else {
            throw DeltaDatabaseError.invalidPayload(table)
        }
        return payload
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

    private static let genericPayloadTables = [
        "repositories",
        "backup_profiles",
        "job_runs",
        "restore_jobs",
        "event_logs"
    ]

    private static let payloadTables = genericPayloadTables + ["snapshots"]

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
