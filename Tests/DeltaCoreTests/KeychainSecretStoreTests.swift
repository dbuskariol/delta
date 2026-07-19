import LocalAuthentication
import Security
import XCTest
@testable import DeltaCore

final class KeychainSecretStoreTests: XCTestCase {
    func testTrustedApplicationPathsFollowInstalledBundleLayout() {
        let paths = KeychainSecretStore.trustedApplicationPaths(
            executablePath: "/Applications/Delta.app/Contents/MacOS/Delta"
        )

        XCTAssertEqual(
            paths,
            [
                "/Applications/Delta.app/Contents/MacOS/Delta",
                "/Applications/Delta.app/Contents/Resources/DeltaAgent",
                "/Applications/Delta.app/Contents/MacOS/DeltaSecretBridge",
                "/Applications/Delta.app/Contents/Resources/DeltaTimeMachineService"
            ]
        )
    }

    func testTrustedApplicationPathsKeepCurrentPackagedHelperExecutable() {
        let paths = KeychainSecretStore.trustedApplicationPaths(
            executablePath: "/Applications/Delta.app/Contents/Resources/DeltaTimeMachineService"
        )

        XCTAssertEqual(paths.first, "/Applications/Delta.app/Contents/Resources/DeltaTimeMachineService")
        XCTAssertTrue(paths.contains("/Applications/Delta.app/Contents/MacOS/Delta"))
    }

    func testDefaultServiceUsesDestinationLanguage() {
        XCTAssertEqual(KeychainSecretStore.defaultService, "com.delta.backup.destination-secrets")
        XCTAssertEqual(KeychainSecretStore.accessPromptName, "Delta destination secrets")
    }

    func testExistingSecretUpdateDoesNotRewriteAccessControl() {
        let attributes = KeychainSecretStore(service: "test")
            .existingItemValueUpdateAttributes(data: Data("replacement".utf8))

        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("replacement".utf8))
        XCTAssertNil(attributes[kSecAttrAccess as String])
        XCTAssertNil(attributes[kSecAttrAccessible as String])
    }

    func testBackgroundLoadQueryFailsInsteadOfPromptingForAuthentication() throws {
        let query = KeychainSecretStore(service: "test").loadQuery(
            account: "account",
            authenticationPolicy: .failIfInteractionNeeded
        )

        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testBackgroundUpdateQueryFailsInsteadOfPromptingForAuthentication() throws {
        let query = KeychainSecretStore(service: "test").updateQuery(
            account: "account",
            authenticationPolicy: .failIfInteractionNeeded
        )

        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testBackgroundAddQueryFailsInsteadOfPromptingForAuthentication() throws {
        let query = KeychainSecretStore(service: "test").addQuery(
            account: "account",
            data: Data("secret".utf8),
            trustedAccess: nil,
            authenticationPolicy: .failIfInteractionNeeded
        )

        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data("secret".utf8))
    }

    func testInteractiveLoadQueryDoesNotForceAuthenticationFailure() {
        let query = KeychainSecretStore(service: "test").loadQuery(
            account: "account",
            authenticationPolicy: .allowUserInteraction
        )

        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testInteractiveAddQueryDoesNotForceAuthenticationFailure() {
        let query = KeychainSecretStore(service: "test").addQuery(
            account: "account",
            data: Data("secret".utf8),
            trustedAccess: nil,
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

    func testUnavailableLoginKeychainHasActionableMessage() {
        XCTAssertEqual(
            KeychainSecretError.keychainUnavailable(errSecNoDefaultKeychain).localizedDescription,
            "macOS could not open the login keychain for Delta (status -25307). Unlock or reset the login keychain in Keychain Access, then try again."
        )
    }
}
