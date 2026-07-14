import XCTest
@testable import DeltaCore

final class BackupIssueTests: XCTestCase {
    func testNestedResticErrorPreservesSpecificCauseAndPath() throws {
        let issue = try XCTUnwrap(ResticLogFormatter.backupIssue(for: """
        {"message_type":"error","error":{"message":"open /Users/me/private: permission denied"},"during":"archival","item":"/Users/me/private"}
        """))

        XCTAssertEqual(issue.path, "/Users/me/private")
        XCTAssertEqual(issue.reason, "open: permission denied")
        XCTAssertEqual(issue.operation, "archival")
        XCTAssertEqual(issue.category, .permissionDenied)
        XCTAssertEqual(
            ResticLogFormatter.displayMessage(for: """
            {"message_type":"error","error":{"message":"open /Users/me/private: permission denied"},"during":"archival","item":"/Users/me/private"}
            """),
            "open: permission denied: /Users/me/private"
        )
    }

    func testIssueCategoriesDistinguishTransientAndPersistentFailures() {
        XCTAssertEqual(BackupIssue(path: "/a", reason: "operation not permitted").category, .permissionDenied)
        XCTAssertEqual(BackupIssue(path: "/a", reason: "file changed as we read it").category, .changedDuringRead)
        XCTAssertEqual(BackupIssue(path: "/a", reason: "no such file or directory").category, .unavailable)
        XCTAssertEqual(BackupIssue(path: "/a", reason: "input/output error").category, .inputOutput)
    }

    func testGroupingUsesCauseAndDoesNotMixUnknownReasons() {
        let groups = BackupIssueGroup.grouped([
            BackupIssue(path: "/one", reason: "permission denied"),
            BackupIssue(path: "/two", reason: "operation not permitted"),
            BackupIssue(path: "/three", reason: "custom failure A"),
            BackupIssue(path: "/four", reason: "custom failure B")
        ])

        XCTAssertEqual(groups.filter { $0.category == .permissionDenied }.first?.issues.count, 2)
        XCTAssertEqual(groups.filter { $0.category == .other }.count, 2)
    }

    func testRecommendationsOnlyCoverKnownGeneratedData() throws {
        let coreSpeech = BackupIssue(
            path: "/Users/me/Library/Group Containers/group.com.apple.CoreSpeech/Caches/model/file",
            reason: "file changed as we read it"
        )
        let mysqlHistory = BackupIssue(path: "/Users/me/.mysql_history", reason: "permission denied")

        let recommendation = try XCTUnwrap(coreSpeech.recommendedExclusion)
        XCTAssertEqual(
            recommendation.pattern,
            "/Users/me/Library/Group Containers/group.com.apple.CoreSpeech/Caches"
        )
        XCTAssertNil(mysqlHistory.recommendedExclusion)
    }

    func testLiteralExclusionEscapesResticGlobMetacharacters() {
        XCTAssertEqual(
            BackupExcludePolicy.literalPattern(for: "/Users/me/[draft]*?.txt"),
            "/Users/me/\\[draft]\\*\\?.txt"
        )
    }

    func testAcknowledgmentFingerprintChangesWithCause() {
        let profileID = UUID()
        let permission = BackupIssue(path: "/private", reason: "permission denied")
        let missing = BackupIssue(path: "/private", reason: "no such file")

        XCTAssertNotEqual(
            permission.acknowledgmentFingerprint(profileID: profileID),
            missing.acknowledgmentFingerprint(profileID: profileID)
        )
    }

    func testAcknowledgmentStoreRequiresEveryIssueToMatch() throws {
        let suiteName = "BackupIssueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BackupIssueAcknowledgmentStore(defaults: defaults)
        let profileID = UUID()
        let first = BackupIssue(path: "/one", reason: "permission denied")
        let second = BackupIssue(path: "/two", reason: "permission denied")

        store.setAcknowledged(true, issues: [first], profileID: profileID)
        XCTAssertTrue(store.isAcknowledged(first, profileID: profileID))
        XCTAssertFalse(store.allAcknowledged([first, second], profileID: profileID))

        store.setAcknowledged(true, issues: [second], profileID: profileID)
        XCTAssertTrue(store.allAcknowledged([first, second], profileID: profileID))

        store.setAcknowledged(false, issues: [first], profileID: profileID)
        XCTAssertFalse(store.isAcknowledged(first, profileID: profileID))
    }
}
