import Foundation

public struct JobNotificationSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var includesSuccessfulBackups: Bool

    public init(isEnabled: Bool, includesSuccessfulBackups: Bool = false) {
        self.isEnabled = isEnabled
        self.includesSuccessfulBackups = includesSuccessfulBackups
    }
}

public struct JobNotificationContent: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public enum JobNotificationPolicy {
    public static func testAlertContent(
        settings: JobNotificationSettings,
        authorizationState: DeltaNotificationAuthorizationState,
        identifier: String = "test-alert"
    ) -> JobNotificationContent? {
        guard settings.isEnabled, authorizationState.canDeliver else {
            return nil
        }

        return JobNotificationContent(
            identifier: identifier,
            title: "Delta test alert",
            body: "Backup notifications are ready."
        )
    }

    public static func content(
        for job: JobRun,
        settings: JobNotificationSettings,
        profileName: String?,
        repositoryName: String?
    ) -> JobNotificationContent? {
        guard settings.isEnabled else {
            return nil
        }

        switch job.status {
        case .failed, .warning:
            return JobNotificationContent(
                identifier: job.id.uuidString,
                title: attentionTitle(for: job),
                body: attentionBody(for: job, profileName: profileName, repositoryName: repositoryName)
            )
        case .succeeded where job.kind == .backup && settings.includesSuccessfulBackups:
            return JobNotificationContent(
                identifier: job.id.uuidString,
                title: "Backup completed",
                body: successBody(for: job, profileName: profileName, repositoryName: repositoryName)
            )
        case .queued, .running, .succeeded, .cancelled:
            return nil
        }
    }

    private static func attentionTitle(for job: JobRun) -> String {
        switch job.status {
        case .warning:
            if job.kind == .backup {
                return "Backup completed with warnings"
            }
            return "\(job.kind.displayName) needs attention"
        case .failed:
            return "\(job.kind.displayName) failed"
        default:
            return job.kind.displayName
        }
    }

    private static func attentionBody(for job: JobRun, profileName: String?, repositoryName: String?) -> String {
        let location = operationLocation(profileName: profileName, repositoryName: repositoryName)
        let message = job.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return "\(location). \(message)"
        }
        return location
    }

    private static func successBody(for job: JobRun, profileName: String?, repositoryName: String?) -> String {
        let location = operationLocation(profileName: profileName, repositoryName: repositoryName)
        if let summary = job.backupSummary {
            return "\(location). \(summary.conciseText)"
        }
        let message = job.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return "\(location). \(message)"
        }
        return location
    }

    private static func operationLocation(profileName: String?, repositoryName: String?) -> String {
        switch (profileName, repositoryName) {
        case let (profile?, repository?):
            return "\(profile) to \(repository)"
        case let (profile?, nil):
            return profile
        case let (nil, repository?):
            return repository
        case (nil, nil):
            return "Delta"
        }
    }
}
