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
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testInteractiveLoadQueryDoesNotForceAuthenticationFailure() {
        let query = KeychainSecretStore(service: "test").loadQuery(
            account: "account",
            authenticationPolicy: .allowUserInteraction
        )

        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testMissingDestinationSecretHasRepairableMessage() {
        XCTAssertEqual(
            KeychainSecretError.itemNotFound.localizedDescription,
            "The saved destination secret is missing. Re-save the destination or repair password access in Settings."
        )
    }
}
