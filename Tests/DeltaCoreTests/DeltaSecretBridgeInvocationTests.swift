import XCTest
@testable import DeltaCore

final class DeltaSecretBridgeInvocationTests: XCTestCase {
    func testSingleAccountArgumentIsAccepted() throws {
        let command = try DeltaSecretBridgeInvocation.command(arguments: ["  repository-account  "])

        XCTAssertEqual(command.keychainAccount, "repository-account")
    }

    func testMissingArgumentFailsClosed() {
        XCTAssertThrowsError(
            try DeltaSecretBridgeInvocation.command(arguments: [])
        ) { error in
            XCTAssertEqual(error as? DeltaSecretBridgeArgumentError, .invalidArgumentCount(0))
        }
    }

    func testExtraArgumentsFailClosed() {
        XCTAssertThrowsError(
            try DeltaSecretBridgeInvocation.command(arguments: ["account", "unexpected"])
        ) { error in
            XCTAssertEqual(error as? DeltaSecretBridgeArgumentError, .invalidArgumentCount(2))
        }
    }

    func testBlankAccountFailsClosed() {
        XCTAssertThrowsError(
            try DeltaSecretBridgeInvocation.command(arguments: ["   "])
        ) { error in
            XCTAssertEqual(error as? DeltaSecretBridgeArgumentError, .emptyAccount)
        }
    }
}
