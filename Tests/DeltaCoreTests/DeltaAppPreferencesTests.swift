import XCTest
@testable import DeltaCore

final class DeltaAppPreferencesTests: XCTestCase {
    func testBoolReadsSharedSuiteBeforeStandardDefaults() {
        let key = "Delta.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)
        suite?.set(true, forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            suite?.removeObject(forKey: key)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: false))
    }

    func testBoolFallsBackToSharedSuiteForHelperProcesses() {
        let key = "Delta.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)
        UserDefaults.standard.removeObject(forKey: key)
        suite?.set(true, forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            suite?.removeObject(forKey: key)
        }

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: false))
    }

    func testBoolUsesDefaultWhenUnset() {
        let key = "Delta.test.\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)?.removeObject(forKey: key)

        XCTAssertTrue(DeltaAppPreferences.bool(for: key, default: true))
    }

    func testStringReadsSharedSuiteBeforeStandardDefaults() {
        let key = "Delta.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: DeltaAppPreferences.sharedSuiteName)
        suite?.set("shared", forKey: key)
        UserDefaults.standard.set("standard", forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            suite?.removeObject(forKey: key)
        }

        XCTAssertEqual(DeltaAppPreferences.string(for: key, default: "fallback"), "shared")
    }
}
