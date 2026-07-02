import Foundation

public enum BackupProgressEstimator {
    private static let maximumRunningFraction = 0.985

    public static func displayedFraction(
        for progress: ResticProgressSnapshot,
        previous: Double?
    ) -> Double? {
        guard let rawFraction = progress.percentDone, rawFraction.isFinite else {
            return previous
        }

        let boundedFraction = min(max(rawFraction, 0), maximumRunningFraction)
        guard let previous else {
            return boundedFraction
        }

        return max(previous, boundedFraction)
    }
}
