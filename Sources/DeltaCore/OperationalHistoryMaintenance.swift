import Foundation

public enum OperationalHistoryMaintenance {
    public static let defaultMinimumRecentJobs = 100

    public static func prune(
        database: DeltaDatabase,
        now: Date = Date(),
        retention: OperationalHistoryRetention = .current(),
        minimumRecentJobs: Int = defaultMinimumRecentJobs
    ) throws -> OperationalHistoryPruneResult {
        guard let cutoff = retention.cutoffDate(now: now) else {
            return OperationalHistoryPruneResult()
        }
        return try database.pruneOperationalHistory(
            olderThan: cutoff,
            minimumRecentJobs: minimumRecentJobs
        )
    }
}
