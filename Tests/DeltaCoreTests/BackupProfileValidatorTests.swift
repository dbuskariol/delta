import XCTest
@testable import DeltaCore

final class BackupProfileValidatorTests: XCTestCase {
    func testNormalizesProfileFields() throws {
        let repositoryID = UUID()
        let profile = BackupProfile(
            name: "  Mac Backup  ",
            sourceMode: .customFolders,
            sources: [
                BackupSource(path: "  ~/Documents/  "),
                BackupSource(path: "\(NSHomeDirectory())/Documents")
            ],
            repositoryID: repositoryID,
            schedule: BackupSchedule(
                kind: .weekly(weekday: 9, hour: 27, minute: -4),
                uploadLimitKiB: 0,
                downloadLimitKiB: 2_000_000
            ),
            retention: RetentionPolicy(
                keepHourly: -1,
                keepDaily: 900,
                keepWeekly: 8,
                keepMonthly: 4,
                keepYearly: 99,
                maintenanceSchedule: RetentionMaintenanceSchedule(intervalDays: 0, hour: 31, minute: -12)
            ),
            excludePatterns: BackupExcludePatternParser.mergingDefaults(with: ["  /tmp/custom  ", "/tmp/custom"])
        )

        let result = try BackupProfileValidator().validate(
            profile,
            knownRepositoryIDs: [repositoryID]
        ).profile

        XCTAssertEqual(result.name, "Mac Backup")
        XCTAssertEqual(result.sources.map(\.path), ["\(NSHomeDirectory())/Documents"])
        XCTAssertEqual(result.schedule.kind, .weekly(weekday: 7, hour: 23, minute: 0))
        XCTAssertNil(result.schedule.uploadLimitKiB)
        XCTAssertEqual(result.schedule.downloadLimitKiB, 1_048_576)
        XCTAssertEqual(result.retention.keepHourly, 0)
        XCTAssertEqual(result.retention.keepDaily, 365)
        XCTAssertEqual(result.retention.keepYearly, 50)
        XCTAssertEqual(result.retention.maintenanceSchedule.intervalDays, 1)
        XCTAssertEqual(result.retention.maintenanceSchedule.hour, 23)
        XCTAssertEqual(result.retention.maintenanceSchedule.minute, 0)
        XCTAssertTrue(result.excludePatterns.contains("/tmp/custom"))
        XCTAssertEqual(
            BackupExcludePatternParser.customPatterns(from: result.excludePatterns),
            ["/tmp/custom"]
        )
    }

    func testRejectsInvalidProfileInputs() {
        let repositoryID = UUID()
        let validator = BackupProfileValidator()

        XCTAssertThrowsError(
            try validator.validate(
                BackupProfile(
                    name: " ",
                    sourceMode: .customFolders,
                    sources: [BackupSource(path: "/Users/me/Documents")],
                    repositoryID: repositoryID
                )
            )
        ) { error in
            XCTAssertEqual(error as? BackupProfileValidationError, .emptyName)
        }

        XCTAssertThrowsError(
            try validator.validate(
                BackupProfile(
                    name: "Documents",
                    sourceMode: .customFolders,
                    sources: [],
                    repositoryID: repositoryID
                )
            )
        ) { error in
            XCTAssertEqual(error as? BackupProfileValidationError, .missingSource)
        }

        XCTAssertThrowsError(
            try validator.validate(
                BackupProfile(
                    name: "Documents",
                    sourceMode: .customFolders,
                    sources: [BackupSource(path: "Documents")],
                    repositoryID: repositoryID
                )
            )
        ) { error in
            XCTAssertEqual(error as? BackupProfileValidationError, .relativeSourcePath("Documents"))
        }

        XCTAssertThrowsError(
            try validator.validate(
                BackupProfile(
                    name: "Documents",
                    sourceMode: .customFolders,
                    sources: [BackupSource(path: "/Users/me/Documents")],
                    repositoryID: repositoryID
                ),
                knownRepositoryIDs: []
            )
        ) { error in
            XCTAssertEqual(error as? BackupProfileValidationError, .missingDestination)
        }
    }
}
