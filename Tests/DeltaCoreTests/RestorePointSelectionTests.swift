import XCTest
@testable import DeltaCore

final class RestorePointSelectionTests: XCTestCase {
    func testReconciledSelectionKeepsCurrentRestorePointWhenAvailable() {
        XCTAssertEqual(
            RestorePointSelection.reconciledSelection(currentID: "older", availableIDs: ["newer", "older"]),
            "older"
        )
    }

    func testReconciledSelectionChoosesNewestPointWhenCurrentIsMissing() {
        XCTAssertEqual(
            RestorePointSelection.reconciledSelection(currentID: "pruned", availableIDs: ["newer", "older"]),
            "newer"
        )
    }

    func testReconciledSelectionChoosesNewestPointWhenCurrentIsEmpty() {
        XCTAssertEqual(
            RestorePointSelection.reconciledSelection(currentID: "", availableIDs: ["newer", "older"]),
            "newer"
        )
    }

    func testReconciledSelectionClearsWhenNoRestorePointsExist() {
        XCTAssertEqual(
            RestorePointSelection.reconciledSelection(currentID: "missing", availableIDs: []),
            ""
        )
    }

    func testScopedSummaryKeySeparatesMatchingRestorePointIDsAcrossDestinations() {
        let firstDestination = UUID()
        let secondDestination = UUID()

        XCTAssertNotEqual(
            RestorePointSelection.scopedSummaryKey(destinationID: firstDestination, restorePointID: "same-restore-point"),
            RestorePointSelection.scopedSummaryKey(destinationID: secondDestination, restorePointID: "same-restore-point")
        )
    }
}
