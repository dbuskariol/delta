import XCTest
@testable import DeltaCore

final class SecurityScopedBookmarkStoreTests: XCTestCase {
    func testMakeSourcePreservesChosenFolderPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try SecurityScopedBookmarkStore().makeSource(from: directory, includeSubvolumes: true)

        XCTAssertEqual(source.path, directory.path)
        XCTAssertTrue(source.includeSubvolumes)
    }
}
