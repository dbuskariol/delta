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

    func testStartupVolumeSourceUsesRootWithoutCrossingVolumes() {
        let source = BackupVolumeSourceFactory().startupVolumeSource()

        XCTAssertEqual(source.path, "/")
        XCTAssertNil(source.bookmarkData)
        XCTAssertFalse(source.includeSubvolumes)
    }

    func testVolumePathNormalizationPreservesRootAndTrimsTrailingSlash() {
        let factory = BackupVolumeSourceFactory()

        XCTAssertEqual(factory.normalizedVolumePath("/"), "/")
        XCTAssertEqual(factory.normalizedVolumePath("/Volumes/Delta/"), "/Volumes/Delta")
        XCTAssertEqual(factory.normalizedVolumePath("   "), "/")
    }

    func testSelectedVolumeSourceResolvesStartupVolumeRoot() {
        let source = BackupVolumeSourceFactory().selectedVolumeSource(from: URL(fileURLWithPath: "/Users"))

        XCTAssertEqual(source.path, "/")
        XCTAssertFalse(source.includeSubvolumes)
    }

    func testSelectedVolumeSourceNormalizesMountedVolumeSubfolder() {
        let source = BackupVolumeSourceFactory().selectedVolumeSource(from: URL(fileURLWithPath: "/Volumes/Delta/Documents"))

        XCTAssertEqual(source.path, "/Volumes/Delta")
        XCTAssertFalse(source.includeSubvolumes)
    }
}
