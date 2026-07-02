import XCTest
@testable import DeltaCore

final class JobNotificationPolicyTests: XCTestCase {
    func testTestAlertRequiresEnabledNotificationsAndDeliverableAuthorization() throws {
        XCTAssertNil(JobNotificationPolicy.testAlertContent(
            settings: JobNotificationSettings(isEnabled: false, includesSuccessfulBackups: true),
            authorizationState: .authorized
        ))
        XCTAssertNil(JobNotificationPolicy.testAlertContent(
            settings: JobNotificationSettings(isEnabled: true),
            authorizationState: .notDetermined
        ))
        XCTAssertNil(JobNotificationPolicy.testAlertContent(
            settings: JobNotificationSettings(isEnabled: true),
            authorizationState: .denied
        ))

        let content = try XCTUnwrap(JobNotificationPolicy.testAlertContent(
            settings: JobNotificationSettings(isEnabled: true),
            authorizationState: .authorized,
            identifier: "manual-test"
        ))

        XCTAssertEqual(content.identifier, "manual-test")
        XCTAssertEqual(content.title, "Delta test alert")
        XCTAssertEqual(content.body, "Backup notifications are ready.")
    }

    func testNotificationsAreSuppressedWhenDisabled() {
        let job = JobRun(repositoryID: UUID(), kind: .backup, status: .failed, message: "Wrong password")

        let content = JobNotificationPolicy.content(
            for: job,
            settings: JobNotificationSettings(isEnabled: false, includesSuccessfulBackups: true),
            profileName: "Mac",
            repositoryName: "SSD"
        )

        XCTAssertNil(content)
    }

    func testFailureNotificationIncludesJobAndDestinationContext() throws {
        let job = JobRun(repositoryID: UUID(), kind: .backup, status: .failed, message: "Wrong password")

        let content = try XCTUnwrap(JobNotificationPolicy.content(
            for: job,
            settings: JobNotificationSettings(isEnabled: true),
            profileName: "Mac",
            repositoryName: "SSD"
        ))

        XCTAssertEqual(content.identifier, job.id.uuidString)
        XCTAssertEqual(content.title, "Backup failed")
        XCTAssertEqual(content.body, "Mac to SSD. Wrong password")
    }

    func testWarningNotificationUsesAttentionCopy() throws {
        let job = JobRun(
            repositoryID: UUID(),
            kind: .backup,
            status: .warning,
            message: "Some files could not be read."
        )

        let content = try XCTUnwrap(JobNotificationPolicy.content(
            for: job,
            settings: JobNotificationSettings(isEnabled: true),
            profileName: "Mac",
            repositoryName: "SSD"
        ))

        XCTAssertEqual(content.title, "Backup completed with warnings")
        XCTAssertEqual(content.body, "Mac to SSD. Some files could not be read.")
    }

    func testSuccessfulBackupNotificationRequiresSuccessOptIn() throws {
        let job = JobRun(
            repositoryID: UUID(),
            kind: .backup,
            status: .succeeded,
            backupSummary: ResticBackupSummary(filesNew: 2, filesChanged: 1, dataAdded: 4096)
        )

        XCTAssertNil(JobNotificationPolicy.content(
            for: job,
            settings: JobNotificationSettings(isEnabled: true, includesSuccessfulBackups: false),
            profileName: "Mac",
            repositoryName: "SSD"
        ))

        let content = try XCTUnwrap(JobNotificationPolicy.content(
            for: job,
            settings: JobNotificationSettings(isEnabled: true, includesSuccessfulBackups: true),
            profileName: "Mac",
            repositoryName: "SSD"
        ))

        XCTAssertEqual(content.title, "Backup completed")
        XCTAssertTrue(content.body.contains("Mac to SSD. 2 new"))
        XCTAssertTrue(content.body.contains("1 changed"))
    }

    func testTransientStatesAndCancelledJobsDoNotNotify() {
        let repositoryID = UUID()
        for status in [JobStatus.queued, .running, .cancelled] {
            let job = JobRun(repositoryID: repositoryID, kind: .backup, status: status)

            let content = JobNotificationPolicy.content(
                for: job,
                settings: JobNotificationSettings(isEnabled: true, includesSuccessfulBackups: true),
                profileName: "Mac",
                repositoryName: "SSD"
            )

            XCTAssertNil(content)
        }
    }
}
