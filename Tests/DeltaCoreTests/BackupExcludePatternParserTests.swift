import XCTest
@testable import DeltaCore

final class BackupExcludePatternParserTests: XCTestCase {
    func testParseAcceptsLinesAndCommasWhileRemovingDuplicates() {
        let patterns = BackupExcludePatternParser.parse(
            """
            /Users/me/Downloads
            *.iso, /Users/me/Downloads

            **/.terraform
            """
        )

        XCTAssertEqual(patterns, ["/Users/me/Downloads", "*.iso", "**/.terraform"])
    }

    func testDisplayTextOnlyShowsCustomPatterns() {
        let patterns = BackupExcludePatternParser.mergingDefaults(
            with: ["/Users/me/Downloads", "*/node_modules"]
        )

        XCTAssertEqual(
            BackupExcludePatternParser.displayText(for: patterns),
            "/Users/me/Downloads"
        )
    }

    func testMergingDefaultsKeepsDefaultSafetyPatterns() {
        let patterns = BackupExcludePatternParser.mergingDefaults(with: ["*.iso"])

        XCTAssertTrue(patterns.contains("/.fseventsd"))
        XCTAssertTrue(patterns.contains("*.iso"))
        XCTAssertEqual(patterns.filter { $0 == "*.iso" }.count, 1)
    }
}
