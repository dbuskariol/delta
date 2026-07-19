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

public struct JobLogCursor: Equatable, Sendable {
    public var createdAt: String
    public var id: String

    public init(createdAt: String, id: String) {
        self.createdAt = createdAt
        self.id = id
    }
}

struct InterruptedTimeMachineConnectionRecovery: Equatable, Sendable {
    var state: TimeMachineDestinationState
    var interruptedJobIDs: [UUID]
}

public struct JobLogPage: Equatable, Sendable {
    public var entries: [JobLogEntry]
    public var totalCount: Int
    public var issueCount: Int
    public var nextCursor: JobLogCursor?
    public var hasMore: Bool

    public init(
        entries: [JobLogEntry],
        totalCount: Int,
        issueCount: Int,
        nextCursor: JobLogCursor?,
        hasMore: Bool
    ) {
        self.entries = entries
        self.totalCount = totalCount
        self.issueCount = issueCount
        self.nextCursor = nextCursor
        self.hasMore = hasMore
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

    public func saveTimeMachineDestinationState(_ state: TimeMachineDestinationState) throws {
        try save(
            state,
            id: state.repositoryID.uuidString,
            table: "time_machine_states",
            repositoryID: state.repositoryID.uuidString
        )
    }

    public func fetchTimeMachineDestinationStates() throws -> [TimeMachineDestinationState] {
        try fetchAll(table: "time_machine_states")
    }

    public func fetchTimeMachineDestinationState(repositoryID: UUID) throws -> TimeMachineDestinationState? {
        let states: [TimeMachineDestinationState] = try fetchAll(
            table: "time_machine_states",
            repositoryID: repositoryID.uuidString
        )
        return states.first
    }

    public func deleteTimeMachineDestinationState(repositoryID: UUID) throws {
        try delete(id: repositoryID.uuidString, table: "time_machine_states")
    }

    public func fetchRepositories() throws -> [BackupRepository] {
        try fetchAll(table: "repositories")
    }

    public func deleteRepository(id: UUID) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM repositories WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM snapshots WHERE repository_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM time_machine_states WHERE repository_id = ?", arguments: [id.uuidString])
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
        try save(
            run,
            id: run.id.uuidString,
            table: "job_runs",
            repositoryID: run.repositoryID.uuidString
        )
    }

    public func fetchJobRuns(limit: Int = 100) throws -> [JobRun] {
        try fetchAll(table: "job_runs", limit: limit)
    }

    /// Atomically reconciles the durable evidence left by an interrupted
    /// Time Machine connection. The caller must hold the repository's local
    /// operation lock, which proves that no Delta app or agent still owns the
    /// connection attempt. The caller supplies a state resolved from public
    /// FSKit, DiskImages/APFS, and tmutil observations; this transaction binds
    /// that evidence to the interrupted job, log, and event atomically.
    func recoverInterruptedTimeMachineSystemOperation(
        repositoryID: UUID,
        expectedStoreID: UUID,
        expectedLifecycle: TimeMachineDestinationLifecycle,
        now: Date,
        resolvedState: TimeMachineDestinationState,
        interruptionMessage: String,
        eventMessage: String
    ) throws -> InterruptedTimeMachineConnectionRecovery? {
        let repositoryIDString = repositoryID.uuidString
        let timestamp = Self.timestampString(now)

        return try queue.write { db in
            guard
                let stateRow = try Row.fetchOne(
                    db,
                    sql: "SELECT payload FROM time_machine_states WHERE id = ?",
                    arguments: [repositoryIDString]
                )
            else {
                return nil
            }
            let statePayload: String = stateRow["payload"]
            guard let stateData = statePayload.data(using: .utf8) else {
                throw DeltaDatabaseError.invalidPayload("time_machine_states")
            }
            var state = try decoder.decode(TimeMachineDestinationState.self, from: stateData)
            guard
                state.lifecycle == expectedLifecycle,
                state.storeID == expectedStoreID,
                resolvedState.repositoryID == repositoryID,
                resolvedState.storeID == expectedStoreID
            else {
                return nil
            }

            let jobRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload FROM job_runs
                WHERE COALESCE(repository_id, json_extract(payload, '$.repositoryID')) = ?
                  AND json_extract(payload, '$.status') = ?
                ORDER BY updated_at DESC
                """,
                arguments: [repositoryIDString, JobStatus.running.rawValue]
            )
            var interruptedJobIDs: [UUID] = []
            for row in jobRows {
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("job_runs")
                }
                var job = try decoder.decode(JobRun.self, from: data)
                guard job.kind == .initializeRepository else {
                    continue
                }
                job.status = .cancelled
                job.finishedAt = now
                job.message = interruptionMessage
                let updatedPayload = try encodedPayload(job, table: "job_runs")
                try db.execute(
                    sql: """
                    UPDATE job_runs
                    SET repository_id = ?, payload = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [repositoryIDString, updatedPayload, timestamp, job.id.uuidString]
                )

                let entry = JobLogEntry(
                    jobID: job.id,
                    profileID: job.profileID,
                    repositoryID: repositoryID,
                    date: now,
                    stream: .standardError,
                    message: interruptionMessage
                )
                let logPayload = try encodedPayload(entry, table: "job_logs")
                try db.execute(
                    sql: """
                    INSERT INTO job_logs (id, job_id, repository_id, stream, payload, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.jobID.uuidString,
                        repositoryIDString,
                        entry.stream.rawValue,
                        logPayload,
                        timestamp
                    ]
                )
                interruptedJobIDs.append(job.id)
            }

            state = resolvedState
            let updatedStatePayload = try encodedPayload(state, table: "time_machine_states")
            try db.execute(
                sql: """
                UPDATE time_machine_states
                SET repository_id = ?, payload = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [repositoryIDString, updatedStatePayload, timestamp, repositoryIDString]
            )

            let event = EventLog(level: .warning, message: eventMessage, createdAt: now)
            let eventPayload = try encodedPayload(event, table: "event_logs")
            try db.execute(
                sql: """
                INSERT INTO event_logs (id, repository_id, payload, created_at, updated_at)
                VALUES (?, NULL, ?, ?, ?)
                """,
                arguments: [event.id.uuidString, eventPayload, timestamp, timestamp]
            )

            return InterruptedTimeMachineConnectionRecovery(
                state: state,
                interruptedJobIDs: interruptedJobIDs
            )
        }
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
                INSERT INTO job_logs (id, job_id, repository_id, stream, payload, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.id.uuidString,
                    entry.jobID.uuidString,
                    entry.repositoryID.uuidString,
                    entry.stream.rawValue,
                    payload,
                    timestamp
                ]
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

    public func fetchJobLogPage(
        jobID: UUID,
        before cursor: JobLogCursor? = nil,
        limit: Int = 200,
        issuesOnly: Bool = false
    ) throws -> JobLogPage {
        let safeLimit = max(1, min(limit, 500))
        let jobIDString = jobID.uuidString

        return try queue.read { db in
            let counts = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    COUNT(*) AS total_count,
                    COALESCE(SUM(
                        CASE WHEN COALESCE(stream, json_extract(payload, '$.stream')) = ?
                        THEN 1 ELSE 0 END
                    ), 0) AS stderr_count,
                    COALESCE(SUM(
                        CASE WHEN json_type(payload, '$.backupIssue') IS NOT NULL
                        THEN 1 ELSE 0 END
                    ), 0) AS structured_issue_count
                FROM job_logs
                WHERE job_id = ?
                """,
                arguments: [ResticOutputStream.standardError.rawValue, jobIDString]
            )
            let totalCount: Int = counts?["total_count"] ?? 0
            let stderrCount: Int = counts?["stderr_count"] ?? 0
            let structuredIssueCount: Int = counts?["structured_issue_count"] ?? 0
            let issueCount = structuredIssueCount > 0 ? structuredIssueCount : stderrCount

            let requestedLimit = safeLimit + 1
            let rows: [Row]
            if let cursor, issuesOnly {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload, created_at FROM job_logs
                    WHERE job_id = ?
                      AND COALESCE(stream, json_extract(payload, '$.stream')) = ?
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [
                        jobIDString,
                        ResticOutputStream.standardError.rawValue,
                        cursor.createdAt,
                        cursor.createdAt,
                        cursor.id,
                        requestedLimit
                    ]
                )
            } else if issuesOnly {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload, created_at FROM job_logs
                    WHERE job_id = ?
                      AND COALESCE(stream, json_extract(payload, '$.stream')) = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [jobIDString, ResticOutputStream.standardError.rawValue, requestedLimit]
                )
            } else if let cursor {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload, created_at FROM job_logs
                    WHERE job_id = ?
                      AND (created_at < ? OR (created_at = ? AND id < ?))
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [jobIDString, cursor.createdAt, cursor.createdAt, cursor.id, requestedLimit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, payload, created_at FROM job_logs
                    WHERE job_id = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [jobIDString, requestedLimit]
                )
            }

            let hasMore = rows.count > safeLimit
            let pageRows = Array(rows.prefix(safeLimit))
            let entries = try pageRows.reversed().map { row in
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("job_logs")
                }
                return try decoder.decode(JobLogEntry.self, from: data)
            }
            let nextCursor = pageRows.last.map { row in
                JobLogCursor(createdAt: row["created_at"], id: row["id"])
            }
            return JobLogPage(
                entries: entries,
                totalCount: totalCount,
                issueCount: issueCount,
                nextCursor: hasMore ? nextCursor : nil,
                hasMore: hasMore
            )
        }
    }

    public func fetchBackupIssues(jobID: UUID) throws -> [BackupIssue] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT payload FROM job_logs
                WHERE job_id = ?
                  AND json_type(payload, '$.backupIssue') IS NOT NULL
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [jobID.uuidString]
            )
            return try rows.compactMap { row in
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("job_logs")
                }
                return try decoder.decode(JobLogEntry.self, from: data).backupIssue
            }
        }
    }

    public func fetchBackupIssues(jobIDs: [UUID]) throws -> [UUID: [BackupIssue]] {
        let uniqueJobIDs = Array(Set(jobIDs))
        guard !uniqueJobIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: uniqueJobIDs.count).joined(separator: ", ")
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT job_id, payload FROM job_logs
                WHERE job_id IN (\(placeholders))
                  AND json_type(payload, '$.backupIssue') IS NOT NULL
                ORDER BY job_id ASC, created_at ASC, id ASC
                """,
                arguments: StatementArguments(uniqueJobIDs.map(\.uuidString))
            )
            var issuesByJobID: [UUID: [BackupIssue]] = [:]
            for row in rows {
                let jobIDString: String = row["job_id"]
                guard let jobID = UUID(uuidString: jobIDString) else {
                    throw DeltaDatabaseError.invalidPayload("job_logs")
                }
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8) else {
                    throw DeltaDatabaseError.invalidPayload("job_logs")
                }
                if let issue = try decoder.decode(JobLogEntry.self, from: data).backupIssue {
                    issuesByJobID[jobID, default: []].append(issue)
                }
            }
            return issuesByJobID
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
                stream TEXT,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
            let jobLogColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(job_logs)")
                .map { row -> String in row["name"] }
            if !jobLogColumns.contains("stream") {
                try db.execute(sql: "ALTER TABLE job_logs ADD COLUMN stream TEXT")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_job_id ON job_logs(job_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_repository_id ON job_logs(repository_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_created_at ON job_logs(created_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_job_cursor ON job_logs(job_id, created_at, id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_job_logs_job_stream_cursor ON job_logs(job_id, stream, created_at, id)")
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
        "time_machine_states",
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
