import XCTest
@testable import DeltaCore

final class BackupProgressEstimatorTests: XCTestCase {
    func testDisplayedFractionUsesCurrentResticProgressWhenStarting() {
        let progress = ResticProgressSnapshot(percentDone: 0.42, displayMessage: "Processed files")

        XCTAssertEqual(BackupProgressEstimator.displayedFraction(for: progress, previous: nil), 0.42)
    }

    func testDisplayedFractionNeverMovesBackwardWhenResticTotalsChange() {
        let progress = ResticProgressSnapshot(percentDone: 0.24, displayMessage: "Processed files")

        XCTAssertEqual(BackupProgressEstimator.displayedFraction(for: progress, previous: 0.61), 0.61)
    }

    func testDisplayedFractionCapsRunningBackupBelowComplete() {
        let progress = ResticProgressSnapshot(percentDone: 1, displayMessage: "Processed files")

        XCTAssertEqual(BackupProgressEstimator.displayedFraction(for: progress, previous: nil), 0.985)
    }

    func testDisplayedFractionKeepsPreviousWhenResticHasNoPercent() {
        let progress = ResticProgressSnapshot(displayMessage: "Scanning")

        XCTAssertEqual(BackupProgressEstimator.displayedFraction(for: progress, previous: 0.31), 0.31)
    }
}
