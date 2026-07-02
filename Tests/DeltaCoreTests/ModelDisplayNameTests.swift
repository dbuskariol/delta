import XCTest
@testable import DeltaCore

final class ModelDisplayNameTests: XCTestCase {
    func testJobStatusDisplayNamesAreUserFacing() {
        XCTAssertEqual(JobStatus.queued.displayName, "Queued")
        XCTAssertEqual(JobStatus.running.displayName, "Running")
        XCTAssertEqual(JobStatus.succeeded.displayName, "Completed")
        XCTAssertEqual(JobStatus.warning.displayName, "Completed with warnings")
        XCTAssertEqual(JobStatus.failed.displayName, "Failed")
        XCTAssertEqual(JobStatus.cancelled.displayName, "Stopped")
    }
}
