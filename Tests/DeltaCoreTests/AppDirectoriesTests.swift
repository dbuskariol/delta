import XCTest
@testable import DeltaCore

final class AppDirectoriesTests: XCTestCase {
    func testApplicationSupportOverrideUsesIsolatedDirectory() throws {
        let key = AppDirectories.applicationSupportOverrideEnvironmentKey
        let original = ProcessInfo.processInfo.environment[key]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-app-support-\(UUID().uuidString)", isDirectory: true)
        defer {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        setenv(key, "  \(directory.path)  ", 1)

        XCTAssertEqual(
            try AppDirectories.applicationSupportDirectory().standardizedFileURL.path,
            directory.standardizedFileURL.path
        )
        XCTAssertEqual(try AppDirectories.databaseURL(), directory.appendingPathComponent("Delta.sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}
