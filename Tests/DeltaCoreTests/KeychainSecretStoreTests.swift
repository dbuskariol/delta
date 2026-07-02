import LocalAuthentication
import Security
import XCTest
@testable import DeltaCore

final class KeychainSecretStoreTests: XCTestCase {
    func testBackgroundLoadQueryFailsInsteadOfPromptingForAuthentication() throws {
        let query = KeychainSecretStore(service: "test").loadQuery(
            account: "account",
            authenticationPolicy: .failIfInteractionNeeded
        )

        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
    }

    func testInteractiveLoadQueryDoesNotForceAuthenticationFailure() {
        let query = KeychainSecretStore(service: "test").loadQuery(
            account: "account",
            authenticationPolicy: .allowUserInteraction
        )

        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }
}
