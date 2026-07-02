import XCTest
@testable import DeltaCore

final class DeltaAgentInvocationTests: XCTestCase {
    func testNoArgumentsRunsDueBackups() throws {
        XCTAssertEqual(try DeltaAgentInvocation.command(arguments: []), .runDueBackups)
    }

    func testStatusArgumentReturnsStatusCommand() throws {
        XCTAssertEqual(try DeltaAgentInvocation.command(arguments: ["--status"]), .status)
    }

    func testDryRunArgumentReturnsNonMutatingDryRunCommand() throws {
        XCTAssertEqual(try DeltaAgentInvocation.command(arguments: ["--dry-run"]), .dryRun)
    }

    func testUnsupportedArgumentsFailClosed() {
        XCTAssertThrowsError(
            try DeltaAgentInvocation.command(arguments: ["--status", "--dry-run"])
        ) { error in
            XCTAssertEqual(error as? DeltaAgentArgumentError, .unsupportedArguments(["--status", "--dry-run"]))
        }

        XCTAssertThrowsError(
            try DeltaAgentInvocation.command(arguments: ["--unknown"])
        ) { error in
            XCTAssertEqual(error as? DeltaAgentArgumentError, .unsupportedArguments(["--unknown"]))
        }
    }
}
