import Foundation
import XCTest
@testable import DeltaCore

final class LaunchAgentRegistrationTests: XCTestCase {
    func testPolicyRegistersAnUnregisteredServiceWhenSchedulesAreEnabled() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .notRegistered,
                hasEnabledSchedules: true,
                registeredFingerprint: nil,
                currentFingerprint: "current"
            ),
            .register
        )
    }

    func testPolicyRepairsNotFoundServiceWhenBundledArtifactsExist() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .notFound,
                hasEnabledSchedules: true,
                registeredFingerprint: nil,
                currentFingerprint: "current"
            ),
            .register
        )
    }

    func testPolicyDoesNotRegisterNotFoundServiceWhenBundledArtifactsAreMissing() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .notFound,
                hasEnabledSchedules: true,
                registeredFingerprint: nil,
                currentFingerprint: nil
            ),
            .none
        )
    }

    func testPolicyReregistersWhenBundledServiceChanged() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .enabled,
                hasEnabledSchedules: true,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .reregister
        )
    }

    func testPolicyReregistersLegacyRegistrationWithoutFingerprint() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .enabled,
                hasEnabledSchedules: true,
                registeredFingerprint: nil,
                currentFingerprint: "current"
            ),
            .reregister
        )
    }

    func testPolicyLeavesCurrentOrDisabledServiceAlone() {
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .enabled,
                hasEnabledSchedules: true,
                registeredFingerprint: "current",
                currentFingerprint: "current"
            ),
            .none
        )
        XCTAssertEqual(
            LaunchAgentRegistrationPolicy.action(
                status: .enabled,
                hasEnabledSchedules: false,
                registeredFingerprint: "old",
                currentFingerprint: "current"
            ),
            .none
        )
    }

    func testFingerprintChangesWithExecutableOrPlist() {
        let original = LaunchAgentRegistrationFingerprint.fingerprint(
            executableData: Data("agent-1".utf8),
            plistData: Data("plist-1".utf8)
        )
        let changedExecutable = LaunchAgentRegistrationFingerprint.fingerprint(
            executableData: Data("agent-2".utf8),
            plistData: Data("plist-1".utf8)
        )
        let changedPlist = LaunchAgentRegistrationFingerprint.fingerprint(
            executableData: Data("agent-1".utf8),
            plistData: Data("plist-2".utf8)
        )

        XCTAssertEqual(original.count, 64)
        XCTAssertNotEqual(original, changedExecutable)
        XCTAssertNotEqual(original, changedPlist)
    }
}
