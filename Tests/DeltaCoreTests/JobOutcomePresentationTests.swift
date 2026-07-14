import XCTest
@testable import DeltaCore

final class JobOutcomePresentationTests: XCTestCase {
    func testAcknowledgedWarningIsCompletedWithoutAttention() {
        let outcome = JobOutcomePresentation(status: .warning, acknowledgedOmissionCount: 6)

        XCTAssertTrue(outcome.hasKnownOmissions)
        XCTAssertEqual(outcome.visualStatus, .succeeded)
        XCTAssertEqual(outcome.displayName, "Completed")
        XCTAssertEqual(outcome.detailText, "6 known omissions")
        XCTAssertFalse(outcome.needsAttention)
    }

    func testUnacknowledgedWarningStillNeedsAttention() {
        let outcome = JobOutcomePresentation(status: .warning)

        XCTAssertFalse(outcome.hasKnownOmissions)
        XCTAssertEqual(outcome.visualStatus, .warning)
        XCTAssertEqual(outcome.displayName, "Completed with warnings")
        XCTAssertNil(outcome.detailText)
        XCTAssertTrue(outcome.needsAttention)
    }

    func testAcknowledgmentCountCannotMaskFailure() {
        let outcome = JobOutcomePresentation(status: .failed, acknowledgedOmissionCount: 6)

        XCTAssertFalse(outcome.hasKnownOmissions)
        XCTAssertEqual(outcome.visualStatus, .failed)
        XCTAssertEqual(outcome.displayName, "Failed")
        XCTAssertTrue(outcome.needsAttention)
    }
}
