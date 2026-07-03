import XCTest
@testable import DeltaCore

final class LocalResticRepositoryStateTests: XCTestCase {
    func testDetectsPreparedLocalDestinationFromConfigFile() throws {
        let root = try temporaryDirectory()
        try Data("{}".utf8).write(to: root.appendingPathComponent("config"))

        let state = LocalResticRepositoryStateInspector().state(path: root.path)

        XCTAssertEqual(state.path, root.path)
        XCTAssertTrue(state.isPrepared)
    }

    func testReportsUnpreparedLocalDestinationWithoutConfigFile() throws {
        let root = try temporaryDirectory()

        let state = LocalResticRepositoryStateInspector().state(path: root.path)

        XCTAssertFalse(state.isPrepared)
    }

    func testIgnoresRemoteDestinations() {
        XCTAssertNil(
            LocalResticRepositoryStateInspector().state(
                for: .sftp(host: "example.com", path: "/backup", username: nil, port: nil, identityFilePath: nil)
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-local-repository-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
